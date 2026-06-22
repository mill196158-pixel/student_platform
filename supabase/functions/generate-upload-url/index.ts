import { createClient } from "npm:@supabase/supabase-js@2";

type UploadRequest = {
  chatId?: unknown;
  fileName?: unknown;
  contentType?: unknown;
  fileSize?: unknown;
  scope?: unknown;
};

type YandexConfig = {
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  endpoint: string;
  region: string;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const expiresIn = 15 * 60;
const maxFileSize = 100 * 1024 * 1024;

class InputError extends Error {}

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

    if (!token) {
      return jsonResponse({ error: "Missing Authorization bearer token" }, 401);
    }

    const supabase = createUserScopedSupabaseClient(authHeader);
    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser(token);

    if (userError || !user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    const body = await req.json() as UploadRequest;
    const input = parseUploadRequest(body);
    const hasAccess = await userCanAccessChat(supabase, user.id, input.chatId);

    if (!hasAccess) {
      return jsonResponse({ error: "Chat access denied" }, 403);
    }

    const yandex = getYandexConfig();
    const fileKey = buildFileKey({
      chatId: input.chatId,
      userId: user.id,
      scope: input.scope,
      fileName: input.fileName,
    });
    const presigned = await createPresignedPutUrl({
      config: yandex,
      key: fileKey,
      contentType: input.contentType,
      expiresIn,
    });

    return jsonResponse({
      uploadUrl: presigned.uploadUrl,
      fileKey,
      fileUrl: presigned.fileUrl,
      expiresIn,
      headers: {
        "Content-Type": input.contentType,
      },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected error";
    const status = error instanceof InputError ? 400 : 500;
    return jsonResponse({ error: message }, status);
  }
});

function createUserScopedSupabaseClient(authHeader: string) {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseKey = Deno.env.get("SUPABASE_ANON_KEY") ?? getDefaultPublishableKey();

  if (!supabaseUrl || !supabaseKey) {
    throw new Error("Missing Supabase function environment");
  }

  return createClient(supabaseUrl, supabaseKey, {
    global: {
      headers: { Authorization: authHeader },
    },
  });
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

function parseUploadRequest(body: UploadRequest) {
  const chatId = asTrimmedString(body.chatId);
  const fileName = asTrimmedString(body.fileName);
  const contentType = asTrimmedString(body.contentType) || "application/octet-stream";
  const scope = sanitizePathSegment(asTrimmedString(body.scope) || "files");
  const fileSize = typeof body.fileSize === "number"
    ? body.fileSize
    : Number(asTrimmedString(body.fileSize));

  if (!isUuid(chatId)) {
    throw new InputError("Invalid chatId");
  }

  if (!fileName || fileName.length > 255) {
    throw new InputError("Invalid fileName");
  }

  if (!Number.isSafeInteger(fileSize) || fileSize <= 0 || fileSize > maxFileSize) {
    throw new InputError("Invalid fileSize");
  }

  if (!/^[a-z0-9][a-z0-9._+/-]{0,126}$/i.test(contentType)) {
    throw new InputError("Invalid contentType");
  }

  return {
    chatId,
    fileName,
    contentType,
    fileSize,
    scope,
  };
}

async function userCanAccessChat(
  supabase: ReturnType<typeof createClient>,
  userId: string,
  chatId: string,
): Promise<boolean> {
  const { data: directMember, error: directMemberError } = await supabase
    .from("chat_members")
    .select("chat_id")
    .eq("chat_id", chatId)
    .eq("user_id", userId)
    .maybeSingle();

  if (directMemberError) {
    throw directMemberError;
  }

  if (directMember) {
    return true;
  }

  const { data: chat, error: chatError } = await supabase
    .from("chats")
    .select("id, team_id")
    .eq("id", chatId)
    .maybeSingle();

  if (chatError) {
    throw chatError;
  }

  const teamId = typeof chat?.team_id === "string" ? chat.team_id : "";
  if (!teamId) {
    return false;
  }

  const { data: teamMember, error: teamMemberError } = await supabase
    .from("team_members")
    .select("team_id")
    .eq("team_id", teamId)
    .eq("user_id", userId)
    .maybeSingle();

  if (teamMemberError) {
    throw teamMemberError;
  }

  return Boolean(teamMember);
}

function getYandexConfig(): YandexConfig {
  const config = {
    accessKeyId: Deno.env.get("YANDEX_ACCESS_KEY_ID") ?? "",
    secretAccessKey: Deno.env.get("YANDEX_SECRET_ACCESS_KEY") ?? "",
    bucket: Deno.env.get("YANDEX_BUCKET") ?? "",
    endpoint: normalizeEndpoint(Deno.env.get("YANDEX_ENDPOINT") ?? "storage.yandexcloud.net"),
    region: Deno.env.get("YANDEX_REGION") ?? "ru-central1",
  };

  for (const [key, value] of Object.entries(config)) {
    if (!value) {
      throw new Error(`Missing ${key} configuration`);
    }
  }

  return config;
}

function buildFileKey(input: {
  chatId: string;
  userId: string;
  scope: string;
  fileName: string;
}) {
  const safeFileName = sanitizeFileName(input.fileName);
  const randomId = crypto.randomUUID();
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");

  return [
    "chats",
    input.chatId,
    input.scope,
    input.userId,
    `${timestamp}_${randomId}_${safeFileName}`,
  ].join("/");
}

async function createPresignedPutUrl(input: {
  config: YandexConfig;
  key: string;
  contentType: string;
  expiresIn: number;
}) {
  const { config, key, contentType } = input;
  const host = `${config.bucket}.${config.endpoint}`;
  const now = new Date();
  const amzDate = toAmzDate(now);
  const dateStamp = amzDate.slice(0, 8);
  const credentialScope = `${dateStamp}/${config.region}/s3/aws4_request`;
  const canonicalUri = `/${encodeS3Key(key)}`;
  const signedHeaders = "content-type;host";
  const query = new URLSearchParams({
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${config.accessKeyId}/${credentialScope}`,
    "X-Amz-Date": amzDate,
    "X-Amz-Expires": String(input.expiresIn),
    "X-Amz-SignedHeaders": signedHeaders,
  });
  const canonicalQueryString = canonicalizeQuery(query);
  const canonicalHeaders = `content-type:${contentType}\nhost:${host}\n`;
  const canonicalRequest = [
    "PUT",
    canonicalUri,
    canonicalQueryString,
    canonicalHeaders,
    signedHeaders,
    "UNSIGNED-PAYLOAD",
  ].join("\n");
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    credentialScope,
    await sha256Hex(canonicalRequest),
  ].join("\n");
  const signingKey = await getSignatureKey(config.secretAccessKey, dateStamp, config.region, "s3");
  const signature = await hmacHex(signingKey, stringToSign);
  const uploadUrl = `https://${host}${canonicalUri}?${canonicalQueryString}&X-Amz-Signature=${signature}`;
  const fileUrl = `https://${host}${canonicalUri}`;

  return { uploadUrl, fileUrl };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

function asTrimmedString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function sanitizePathSegment(value: string): string {
  const sanitized = value.toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  return sanitized || "files";
}

function sanitizeFileName(value: string): string {
  const withoutPath = value.split(/[\\/]/).pop() ?? "file";
  const sanitized = withoutPath
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .replace(/[^a-zA-Z0-9._ -]+/g, "_")
    .replace(/\s+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 120);

  return sanitized || "file";
}

function normalizeEndpoint(value: string): string {
  return value.replace(/^https?:\/\//i, "").replace(/\/+$/g, "");
}

function encodeS3Key(key: string): string {
  return key.split("/").map((part) => encodeURIComponent(part)).join("/");
}

function canonicalizeQuery(params: URLSearchParams): string {
  return [...params.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join("&");
}

function toAmzDate(date: Date): string {
  return date.toISOString().replace(/[:-]|\.\d{3}/g, "");
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToHex(new Uint8Array(digest));
}

async function hmac(key: Uint8Array, value: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(value));
  return new Uint8Array(signature);
}

async function hmacHex(key: Uint8Array, value: string): Promise<string> {
  return bytesToHex(await hmac(key, value));
}

async function getSignatureKey(secret: string, dateStamp: string, region: string, service: string): Promise<Uint8Array> {
  const kDate = await hmac(new TextEncoder().encode(`AWS4${secret}`), dateStamp);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, service);
  return await hmac(kService, "aws4_request");
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
