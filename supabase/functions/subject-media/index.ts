import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

type UserClient = SupabaseClient<any, "public", any>;
type ServiceClient = SupabaseClient<any, "public", any>;

type SubjectMediaRequest = {
  action?: unknown;
  subjectCatalogId?: unknown;
  subjectOfferingId?: unknown;
  assetKind?: unknown;
  contentType?: unknown;
  fileSize?: unknown;
  logicalAssetId?: unknown;
  intentId?: unknown;
  title?: unknown;
  checksum?: unknown;
  supersedesAssetId?: unknown;
  assetId?: unknown;
  offeringId?: unknown;
  limit?: unknown;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BUCKET = "subject-media";
const MAX_BYTES = 20 * 1024 * 1024;
const HERO_MIME = new Set(["image/jpeg", "image/png", "image/webp"]);
const ATTACHMENT_MIME = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
]);
const UPLOAD_EXPIRES = 15 * 60;
const DOWNLOAD_EXPIRES = 60 * 60;
const CLEANUP_BATCH_MAX = 25;

class InputError extends Error {}
class AuthError extends Error {}
class ForbiddenError extends Error {}

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

    const body = (await req.json()) as SubjectMediaRequest;
    const action = asTrimmedString(body.action) || "createUpload";
    const service = createServiceClient();

    // Cleanup worker: service/cleanup secret only (never ordinary user JWTs).
    if (action === "processCleanup") {
      assertTrustedCleanupCaller(req);
      const limit = parseCleanupLimit(body.limit);
      const { data: batch, error: claimError } = await service.rpc(
        "claim_subject_media_cleanup_batch",
        { p_limit: limit, p_lease_seconds: 600 },
      );
      if (claimError) throw new Error(claimError.message);
      const rows = normalizeJsonArray(batch);
      let completed = 0;
      let failed = 0;
      for (const row of rows) {
        const queueId = asUuid(row.id);
        const claimToken = asUuid(row.claim_token);
        const storagePath = asTrimmedString(row.storage_path);
        if (!queueId || !claimToken || !storagePath) {
          failed += 1;
          continue;
        }
        try {
          const { error: removeError } = await service.storage.from(BUCKET)
            .remove([storagePath]);
          if (removeError) throw removeError;
          const { error: completeError } = await service.rpc(
            "complete_subject_media_cleanup",
            { p_queue_id: queueId, p_claim_token: claimToken },
          );
          if (completeError) throw completeError;
          completed += 1;
        } catch (cleanupError) {
          failed += 1;
          const message = cleanupError instanceof Error
            ? cleanupError.message
            : "cleanup_failed";
          await service.rpc("fail_subject_media_cleanup", {
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
      await assertCanManageSubjectMedia(userClient);
      const input = parseUpload(body);
      const owner = parseOwner(body);
      const { data: intent, error: intentError } = await userClient.rpc(
        "admin_create_subject_asset_upload_intent",
        {
          p_subject_catalog_id: owner.catalogId,
          p_subject_offering_id: owner.offeringId,
          p_asset_kind: input.assetKind,
          p_mime_type: input.contentType,
          p_logical_asset_id: input.logicalAssetId,
          p_ttl_seconds: UPLOAD_EXPIRES,
        },
      );
      if (intentError || !intent) {
        throw new Error(intentError?.message ?? "Failed to create upload intent");
      }
      const path = asTrimmedString(intent.storage_path);
      if (!path) throw new Error("Upload intent missing storage_path");

      const { data, error } = await service.storage
        .from(BUCKET)
        .createSignedUploadUrl(path);
      if (error || !data) {
        throw new Error(error?.message ?? "Failed to create upload URL");
      }
      return jsonResponse({
        action: "createUpload",
        intentId: intent.intent_id,
        assetKind: intent.asset_kind,
        logicalAssetId: intent.logical_asset_id,
        path,
        token: data.token,
        signedUrl: data.signedUrl,
        expiresIn: UPLOAD_EXPIRES,
        expiresAt: intent.expires_at,
        headers: { "Content-Type": input.contentType },
      });
    }

    if (action === "finalizeUpload") {
      await assertCanManageSubjectMedia(userClient);
      const intentId = asUuid(body.intentId);
      if (!intentId) throw new InputError("Invalid intentId");
      const { data, error } = await userClient.rpc(
        "admin_finalize_subject_asset_upload",
        {
          p_intent_id: intentId,
          p_title: asTrimmedString(body.title),
          p_checksum: asTrimmedString(body.checksum) || null,
          p_supersedes_asset_id: asUuid(body.supersedesAssetId),
        },
      );
      if (error) throw new Error(error.message);
      return jsonResponse({ action: "finalizeUpload", asset: data });
    }

    if (action === "createDownload") {
      const assetId = asUuid(body.assetId);
      const offeringId = asUuid(body.offeringId);
      if (!assetId || !offeringId) {
        throw new InputError("assetId and offeringId required");
      }
      const { data: authData, error: authError } = await userClient.rpc(
        "authorize_subject_asset_download",
        {
          p_asset_id: assetId,
          p_subject_offering_id: offeringId,
        },
      );
      if (authError || authData?.authorized !== true) {
        throw new ForbiddenError("download denied");
      }

      const { data: target, error: targetError } = await service.rpc(
        "service_subject_asset_storage_path",
        { p_asset_id: assetId },
      );
      if (targetError || !target) {
        throw new ForbiddenError("download denied");
      }
      const path = asTrimmedString(target.storage_path);
      if (!path) throw new ForbiddenError("download denied");

      const { data: signed, error: signError } = await service.storage
        .from(BUCKET)
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
    const message = error instanceof Error ? error.message : "Unexpected error";
    const status = error instanceof AuthError
      ? 401
      : error instanceof ForbiddenError
      ? 403
      : error instanceof InputError
      ? 400
      : 500;
    return jsonResponse({ error: message }, status);
  }
});

async function assertCanManageSubjectMedia(userClient: UserClient): Promise<void> {
  const { data, error } = await userClient.rpc("admin_can_manage_subject_media");
  if (error) throw new Error(error.message);
  if (data !== true) throw new ForbiddenError("subjects.write required");
}

function parseOwner(body: SubjectMediaRequest) {
  const catalogId = asUuid(body.subjectCatalogId);
  const offeringId = asUuid(body.subjectOfferingId);
  if ((catalogId == null) === (offeringId == null)) {
    throw new InputError("Exactly one of subjectCatalogId or subjectOfferingId");
  }
  return { catalogId, offeringId };
}

function parseUpload(body: SubjectMediaRequest) {
  const assetKind = asTrimmedString(body.assetKind) || "attachment";
  if (assetKind !== "hero_image" && assetKind !== "attachment") {
    throw new InputError("assetKind must be hero_image or attachment");
  }
  const contentType = asTrimmedString(body.contentType).toLowerCase();
  const allowed = assetKind === "hero_image" ? HERO_MIME : ATTACHMENT_MIME;
  if (!allowed.has(contentType)) {
    throw new InputError("MIME type not allowed for assetKind");
  }
  const fileSize = parseByteSize(body.fileSize, false);
  return {
    assetKind,
    contentType,
    fileSize,
    logicalAssetId: asUuid(body.logicalAssetId),
  };
}

function parseByteSize(value: unknown, optional: boolean): number {
  if (value == null || value === "") {
    if (optional) return 0;
    throw new InputError("fileSize required");
  }
  const n = typeof value === "number" ? value : Number(asTrimmedString(value));
  if (!Number.isSafeInteger(n) || n <= 0 || n > MAX_BYTES) {
    throw new InputError(`fileSize must be 1..${MAX_BYTES} bytes`);
  }
  return n;
}

function parseCleanupLimit(value: unknown): number {
  if (value == null || value === "") return 10;
  const n = typeof value === "number" ? value : Number(asTrimmedString(value));
  if (!Number.isSafeInteger(n) || n <= 0) return 10;
  return Math.min(n, CLEANUP_BATCH_MAX);
}

function normalizeJsonArray(data: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(data)) {
    return data.filter((x): x is Record<string, unknown> =>
      !!x && typeof x === "object"
    );
  }
  if (typeof data === "string") {
    try {
      return normalizeJsonArray(JSON.parse(data));
    } catch {
      return [];
    }
  }
  return [];
}

function asUuid(value: unknown): string | null {
  const s = asTrimmedString(value);
  if (!s) return null;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(s)
    ? s
    : null;
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

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
