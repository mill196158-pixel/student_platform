// Stage 16.3 / 14.2.1 content-media Edge (deploy owner-gated).
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

type UserClient = SupabaseClient<any, "public", any>;
type ServiceClient = SupabaseClient<any, "public", any>;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BUCKET = "content-media";
const UPLOAD_EXPIRES = 15 * 60;
const DOWNLOAD_EXPIRES = 60 * 60;
const CLEANUP_BATCH_MAX = 25;

class AuthError extends Error {
  constructor(message = "Unauthorized") {
    super(message);
    this.name = "AuthError";
  }
}
class ForbiddenError extends Error {
  constructor(message = "forbidden") {
    super(message);
    this.name = "ForbiddenError";
  }
}
class InputError extends Error {
  constructor(message = "invalid_input") {
    super(message);
    this.name = "InputError";
  }
}
class BusinessError extends Error {
  readonly code: string;
  readonly status: number;
  constructor(code: string, status: number) {
    super(code);
    this.name = "BusinessError";
    this.code = code;
    this.status = status;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) throw new AuthError("Missing Authorization bearer token");

    const body = await req.json() as Record<string, unknown>;
    const action = asTrimmedString(body.action) || "createDownload";
    const service = createServiceClient();

    if (action === "processCleanup") {
      assertTrustedCleanupCaller(req);
      const limit = parseCleanupLimit(body.limit);
      const { data: batch, error: claimError } = await service.rpc(
        "claim_content_media_cleanup_batch",
        { p_limit: limit, p_lease_seconds: 600 },
      );
      if (claimError) throw new Error(claimError.message);
      const rows = Array.isArray(batch) ? batch : [];
      let completed = 0;
      let failed = 0;
      for (const row of rows) {
        const queueId = asUuid((row as Record<string, unknown>).id);
        const claimToken = asUuid((row as Record<string, unknown>).claim_token);
        const storagePath = asTrimmedString(
          (row as Record<string, unknown>).storage_path,
        );
        const bucket = asTrimmedString(
          (row as Record<string, unknown>).storage_bucket,
        ) || BUCKET;
        if (!queueId || !claimToken || !storagePath) {
          failed += 1;
          continue;
        }
        try {
          const { error: removeError } = await service.storage.from(bucket)
            .remove([storagePath]);
          if (removeError) throw removeError;
          const { error: completeError } = await service.rpc(
            "complete_content_media_cleanup",
            { p_queue_id: queueId, p_claim_token: claimToken },
          );
          if (completeError) throw completeError;
          completed += 1;
        } catch (cleanupError) {
          failed += 1;
          const message = cleanupError instanceof Error
            ? cleanupError.message
            : "cleanup_failed";
          await service.rpc("fail_content_media_cleanup", {
            p_queue_id: queueId,
            p_claim_token: claimToken,
            p_error: message,
          });
        }
      }
      return jsonResponse({
        action: "processCleanup",
        claimed: rows.length,
        completed,
        failed,
      });
    }

    const userClient = createUserScopedClient(authHeader);
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser(token);
    if (userError || !user) throw new AuthError("Unauthorized");

    if (action === "createUpload") {
      const contentItemId = asUuid(body.contentItemId);
      const contentType = asTrimmedString(body.contentType).toLowerCase();
      if (!contentItemId) throw new InputError("contentItemId required");
      const { data: intent, error: intentError } = await userClient.rpc(
        "admin_create_content_asset_upload_intent",
        {
          p_content_item_id: contentItemId,
          p_mime_type: contentType,
          p_ttl_seconds: UPLOAD_EXPIRES,
        },
      );
      if (intentError || !intent) {
        throw mapRpcError(intentError);
      }
      const intentId = asUuid(intent.intent_id);
      if (!intentId) throw new Error("Upload intent missing intent_id");
      // Path stays service-side; authenticated intent RPC must not return it.
      if (asTrimmedString(intent.storage_path)) {
        throw new Error("Upload intent leaked storage_path");
      }
      const { data: target, error: targetError } = await service.rpc(
        "service_content_upload_intent_storage_path",
        { p_intent_id: intentId },
      );
      if (targetError || !target) {
        throw mapRpcError(targetError, "Failed to resolve upload path");
      }
      const path = asTrimmedString(target.storage_path);
      const bucket = asTrimmedString(target.storage_bucket) || BUCKET;
      if (!path) throw new Error("Upload intent missing storage_path");
      const { data, error } = await service.storage
        .from(bucket)
        .createSignedUploadUrl(path);
      if (error || !data) {
        throw new Error(error?.message ?? "Failed to create upload URL");
      }
      return jsonResponse({
        action: "createUpload",
        intentId,
        token: data.token,
        signedUrl: data.signedUrl,
        expiresIn: UPLOAD_EXPIRES,
        expiresAt: intent.expires_at,
        headers: { "Content-Type": contentType },
      });
    }

    if (action === "finalizeUpload") {
      const intentId = asUuid(body.intentId);
      if (!intentId) throw new InputError("Invalid intentId");
      const { data, error } = await userClient.rpc(
        "admin_finalize_content_asset_upload",
        {
          p_intent_id: intentId,
          p_title: asTrimmedString(body.title),
        },
      );
      if (error) throw mapRpcError(error);
      return jsonResponse({ action: "finalizeUpload", asset: data });
    }

    if (action === "createDownload") {
      const assetId = asUuid(body.assetId);
      if (!assetId) throw new InputError("assetId required");
      const { data: authData, error: authError } = await userClient.rpc(
        "authorize_content_asset_download",
        { p_asset_id: assetId },
      );
      if (authError || authData?.authorized !== true) {
        throw new ForbiddenError("download denied");
      }
      const { data: target, error: targetError } = await service.rpc(
        "service_content_asset_storage_path",
        { p_asset_id: assetId },
      );
      if (targetError || !target) throw new ForbiddenError("download denied");
      const path = asTrimmedString(target.storage_path);
      const bucket = asTrimmedString(target.storage_bucket) || BUCKET;
      if (!path) throw new ForbiddenError("download denied");

      const { data: signed, error: signError } = await service.storage
        .from(bucket)
        .createSignedUrl(path, DOWNLOAD_EXPIRES);
      if (signError || !signed?.signedUrl) {
        throw new Error(signError?.message ?? "Failed to create download URL");
      }
      return jsonResponse({
        action: "createDownload",
        assetId,
        mimeType: authData?.mime_type ?? null,
        signedUrl: signed.signedUrl,
        expiresIn: DOWNLOAD_EXPIRES,
      });
    }

    throw new InputError("Unknown action");
  } catch (error) {
    if (error instanceof BusinessError) {
      return jsonResponse({ error: error.code }, error.status);
    }
    const message = error instanceof Error ? error.message : "Unexpected error";
    const status = error instanceof AuthError
      ? 401
      : error instanceof ForbiddenError
      ? 403
      : error instanceof InputError
      ? 400
      : 500;
    // Never leak raw DB diagnostics for unexpected 500s.
    const safe = status === 500 ? "internal_error" : normalizeBusinessCode(message);
    return jsonResponse({ error: safe }, status);
  }
});

function mapRpcError(
  error: { message?: string; code?: string } | null | undefined,
  fallback = "rpc_failed",
): Error {
  const raw = asTrimmedString(error?.message) || fallback;
  const code = normalizeBusinessCode(raw);
  const status = statusForBusinessCode(code);
  if (status != null) return new BusinessError(code, status);
  if (error?.code === "42501" || /forbidden|permission/i.test(raw)) {
    return new ForbiddenError("forbidden");
  }
  return new Error(fallback);
}

function normalizeBusinessCode(message: string): string {
  const lower = message.toLowerCase();
  const known = [
    "working_draft_required",
    "draft_only",
    "archived_immutable",
    "row_version_conflict",
    "intent_expired",
    "intent_already_finalized",
    "invalid_mime",
    "mime_mismatch",
    "invalid_byte_size",
    "storage_mime_missing",
    "storage_object_missing",
    "invalid_storage_path",
    "not_found",
    "forbidden",
  ];
  for (const code of known) {
    if (lower.includes(code)) return code;
  }
  // PostgREST often prefixes: "working_draft_required"
  const first = message.split(/[\s:]+/)[0]?.trim().toLowerCase() ?? "";
  if (known.includes(first)) return first;
  return message.length > 80 ? "rpc_failed" : message;
}

function statusForBusinessCode(code: string): number | null {
  switch (code) {
    case "working_draft_required":
    case "draft_only":
    case "archived_immutable":
    case "row_version_conflict":
    case "intent_expired":
    case "intent_already_finalized":
      return 409;
    case "invalid_mime":
    case "mime_mismatch":
    case "invalid_byte_size":
    case "storage_mime_missing":
    case "invalid_storage_path":
      return 422;
    case "forbidden":
      return 403;
    case "not_found":
    case "storage_object_missing":
      return 404;
    default:
      return null;
  }
}

function assertTrustedCleanupCaller(req: Request): void {
  const cleanupSecret = Deno.env.get("CLEANUP_DISPATCH_SECRET")?.trim();
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new AuthError("unauthorized: missing bearer");
  const allowed = new Set<string>();
  if (cleanupSecret) allowed.add(cleanupSecret);
  if (serviceRole) allowed.add(serviceRole);
  if (allowed.size === 0) {
    throw new AuthError("unauthorized: server secrets not configured");
  }
  if (!allowed.has(token)) {
    throw new ForbiddenError("unauthorized: invalid cleanup bearer");
  }
}

function parseCleanupLimit(value: unknown): number {
  if (value == null || value === "") return 10;
  const n = typeof value === "number" ? value : Number(asTrimmedString(value));
  if (!Number.isSafeInteger(n) || n <= 0) return 10;
  return Math.min(n, CLEANUP_BATCH_MAX);
}

function createUserScopedClient(authHeader: string): UserClient {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    getDefaultPublishableKey();
  if (!supabaseUrl || !supabaseKey) {
    throw new Error("Missing Supabase function environment");
  }
  return createClient(supabaseUrl, supabaseKey, {
    global: { headers: { Authorization: authHeader } },
  }) as UserClient;
}

function createServiceClient(): ServiceClient {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) {
    throw new Error("Missing service role environment");
  }
  return createClient(supabaseUrl, serviceKey) as ServiceClient;
}

function getDefaultPublishableKey(): string | undefined {
  const raw = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw) as Record<string, string>;
    return parsed.default;
  } catch {
    return undefined;
  }
}

function asTrimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function asUuid(value: unknown): string | null {
  const s = asTrimmedString(value);
  if (!s) return null;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(s)
    ? s
    : null;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
