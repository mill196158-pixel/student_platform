import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

type UserClient = SupabaseClient<any, "public", any>;
type ServiceClient = SupabaseClient<any, "public", any>;

type NewsMediaRequest = {
  action?: unknown;
  fileName?: unknown;
  contentType?: unknown;
  fileSize?: unknown;
  path?: unknown;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const BUCKET = "news-media";
const MAX_BYTES = 5 * 1024 * 1024;
const ALLOWED_MIME = new Set(["image/jpeg", "image/png", "image/webp"]);
const UPLOAD_EXPIRES = 15 * 60;
const DOWNLOAD_EXPIRES = 60 * 60;

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

    const userClient = createUserScopedClient(authHeader);
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser(token);
    if (userError || !user) throw new AuthError("Unauthorized");

    const body = (await req.json()) as NewsMediaRequest;
    const action = asTrimmedString(body.action) || "createUpload";
    const service = createServiceClient();

    if (action === "createUpload") {
      await assertCanManageMedia(userClient);
      const input = parseUpload(body);
      const path = buildSafePath(user.id, input.fileName, input.contentType);
      const { data, error } = await service.storage
        .from(BUCKET)
        .createSignedUploadUrl(path);
      if (error || !data) {
        throw new Error(error?.message ?? "Failed to create upload URL");
      }
      return jsonResponse({
        action: "createUpload",
        path,
        token: data.token,
        signedUrl: data.signedUrl,
        expiresIn: UPLOAD_EXPIRES,
        headers: { "Content-Type": input.contentType },
      });
    }

    if (action === "createDownload") {
      const path = sanitizeStoragePath(asTrimmedString(body.path));
      if (!path) throw new InputError("Invalid path");
      await assertCanDownload(userClient, path);
      const { data, error } = await service.storage
        .from(BUCKET)
        .createSignedUrl(path, DOWNLOAD_EXPIRES);
      if (error || !data?.signedUrl) {
        throw new Error(error?.message ?? "Failed to create download URL");
      }
      return jsonResponse({
        action: "createDownload",
        path,
        signedUrl: data.signedUrl,
        expiresIn: DOWNLOAD_EXPIRES,
      });
    }

    if (action === "delete") {
      await assertCanManageMedia(userClient);
      const path = sanitizeStoragePath(asTrimmedString(body.path));
      if (!path) throw new InputError("Invalid path");
      const { error } = await service.storage.from(BUCKET).remove([path]);
      if (error) throw new Error(error.message);
      return jsonResponse({ action: "delete", path, ok: true });
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

async function assertCanManageMedia(userClient: UserClient): Promise<void> {
  const { data, error } = await userClient.rpc("admin_can_manage_news_media");
  if (error) throw new Error(error.message);
  if (data !== true) throw new ForbiddenError("content.write required");
}

async function assertCanDownload(
  userClient: UserClient,
  path: string,
): Promise<void> {
  const { data: canRead } = await userClient.rpc("admin_can_read_news_media");
  if (canRead === true) return;

  // Students: path must belong to a currently visible published post.
  const { data, error } = await userClient.rpc("get_my_published_news");
  if (error) throw new ForbiddenError("download denied");
  const asList = normalizeJsonArray(data);
  const ok = asList.some((item) => item?.["image_path"] === path);
  if (!ok) throw new ForbiddenError("download denied");
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

function parseUpload(body: NewsMediaRequest) {
  const fileName = asTrimmedString(body.fileName);
  const contentType = asTrimmedString(body.contentType).toLowerCase();
  const fileSize = typeof body.fileSize === "number"
    ? body.fileSize
    : Number(asTrimmedString(body.fileSize));

  if (!fileName || fileName.length > 180) {
    throw new InputError("Invalid fileName");
  }
  if (!ALLOWED_MIME.has(contentType)) {
    throw new InputError("Only JPG/PNG/WebP allowed");
  }
  if (!Number.isSafeInteger(fileSize) || fileSize <= 0 || fileSize > MAX_BYTES) {
    throw new InputError("fileSize must be 1..5242880 bytes");
  }
  return { fileName, contentType, fileSize };
}

function buildSafePath(
  userId: string,
  fileName: string,
  contentType: string,
): string {
  const ext = contentType === "image/png"
    ? "png"
    : contentType === "image/webp"
    ? "webp"
    : "jpg";
  const stamp = crypto.randomUUID();
  // Ignore client fileName for path safety; keep only extension class.
  void fileName;
  return `news/${userId}/${stamp}.${ext}`;
}

function sanitizeStoragePath(path: string): string {
  if (!path) return "";
  if (path.includes("..") || path.startsWith("/") || path.includes("\\")) {
    return "";
  }
  if (!/^news\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp)$/i.test(path)) {
    return "";
  }
  return path;
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

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
