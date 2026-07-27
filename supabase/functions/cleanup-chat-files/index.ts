import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

// Untyped service client: RPCs are not in generated Database types.
type ServiceClient = SupabaseClient<any, "public", any>;

type ClaimedRow = {
  id: string;
  chat_id: string;
  chat_file_id: string;
  file_key: string;
  attempts: number;
};

type DeletionTarget = {
  queue_id: string;
  chat_id: string;
  chat_file_id: string;
  file_key: string | null;
  eligible: boolean;
  skip_reason: string | null;
};

type YandexConfig = {
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
  endpoint: string;
  region: string;
};

const maxBatch = 25;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return jsonResponse({ ok: true }, 200);
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    assertTrustedCaller(req);

    const supabase = createServiceClient();
    const yandex = getYandexConfig();

    const { data: claimed, error: claimError } = await supabase.rpc(
      "claim_pending_chat_file_cleanup",
      { p_limit: maxBatch },
    );

    if (claimError) {
      throw new Error(`claim_failed: ${claimError.message}`);
    }

    const rows = (claimed ?? []) as ClaimedRow[];
    let deleted = 0;
    let skipped = 0;
    let failed = 0;
    let retried = 0;

    for (const row of rows) {
      try {
        const outcome = await processQueueRow({ supabase, yandex, row });
        if (outcome === "done") deleted += 1;
        else if (outcome === "skipped") skipped += 1;
        else if (outcome === "retry") retried += 1;
        else failed += 1;
      } catch (error) {
        failed += 1;
        const message = error instanceof Error ? error.message : String(error);
        await supabase.rpc("complete_chat_file_cleanup", {
          p_queue_id: row.id,
          p_outcome: row.attempts >= 8 ? "failed" : "retry",
          p_error_code: "worker_exception",
          p_error_message: message.slice(0, 500),
          p_http_status: null,
          p_retry_seconds: backoffSeconds(row.attempts),
        });
      }
    }

    return jsonResponse({
      ok: true,
      claimed: rows.length,
      deleted,
      skipped,
      failed,
      retried,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.startsWith("unauthorized") ? 401 : 500;
    return jsonResponse({ error: sanitizeLogMessage(message) }, status);
  }
});

async function processQueueRow(input: {
  supabase: ServiceClient;
  yandex: YandexConfig;
  row: ClaimedRow;
}): Promise<"done" | "skipped" | "failed" | "retry"> {
  const { supabase, yandex, row } = input;

  const { data: targets, error: targetError } = await supabase.rpc(
    "get_chat_file_cleanup_deletion_target",
    { p_queue_id: row.id },
  );

  if (targetError) {
    throw new Error(`validate_failed: ${targetError.message}`);
  }

  const target = Array.isArray(targets)
    ? targets[0] as DeletionTarget | undefined
    : targets as DeletionTarget | undefined;

  if (!target) {
    await supabase.rpc("complete_chat_file_cleanup", {
      p_queue_id: row.id,
      p_outcome: "failed",
      p_error_code: "validate_empty",
      p_error_message: "no_deletion_target",
      p_http_status: null,
      p_retry_seconds: null,
    });
    return "failed";
  }

  if (!target.eligible) {
    const reason = target.skip_reason ?? "not_eligible";

    // Temporary: keep data, retry later. Do not clear metadata.
    if (reason === "not_expired" || reason === "retention_not_ended") {
      await supabase.rpc("complete_chat_file_cleanup", {
        p_queue_id: row.id,
        p_outcome: "retry",
        p_error_code: reason,
        p_error_message: reason,
        p_http_status: null,
        p_retry_seconds: 3600,
      });
      return "retry";
    }

    // Safe no-op only: metadata already cleared / queue already done.
    if (reason === "file_already_cleared" || reason === "already_done") {
      await supabase.rpc("complete_chat_file_cleanup", {
        p_queue_id: row.id,
        p_outcome: "skipped",
        p_error_code: reason,
        p_error_message: reason,
        p_http_status: null,
        p_retry_seconds: null,
      });
      return "skipped";
    }

    // archive_missing, invalid_file_key, missing_file_key, etc. → manual review.
    // Must NOT clear chat_files metadata.
    await supabase.rpc("complete_chat_file_cleanup", {
      p_queue_id: row.id,
      p_outcome: "failed",
      p_error_code: reason,
      p_error_message: reason,
      p_http_status: null,
      p_retry_seconds: null,
    });
    return "failed";
  }

  const fileKey = (target.file_key ?? "").trim();
  if (!fileKey || !isTrustedObjectKey(fileKey)) {
    await supabase.rpc("complete_chat_file_cleanup", {
      p_queue_id: row.id,
      p_outcome: "failed",
      p_error_code: "invalid_file_key",
      p_error_message: "rejected_untrusted_key",
      p_http_status: null,
      p_retry_seconds: null,
    });
    return "failed";
  }

  const deleteResult = await deleteYandexObject({ config: yandex, key: fileKey });

  if (!deleteResult.ok && deleteResult.status !== 404) {
    const outcome = row.attempts >= 8 ? "failed" : "retry";
    await supabase.rpc("complete_chat_file_cleanup", {
      p_queue_id: row.id,
      p_outcome: outcome,
      p_error_code: "yandex_delete_failed",
      p_error_message: `http_${deleteResult.status}`,
      p_http_status: deleteResult.status,
      p_retry_seconds: backoffSeconds(row.attempts),
    });
    return outcome;
  }

  // 404 = object already absent → skipped (safe to clear local metadata).
  // 2xx = deleted now → done.
  const outcome = deleteResult.status === 404 ? "skipped" : "done";
  await supabase.rpc("complete_chat_file_cleanup", {
    p_queue_id: row.id,
    p_outcome: outcome,
    p_error_code: outcome === "skipped" ? "object_already_absent" : null,
    p_error_message: outcome === "skipped" ? "object_already_absent" : null,
    p_http_status: deleteResult.status,
    p_retry_seconds: null,
  });
  return outcome;
}

function assertTrustedCaller(req: Request): void {
  const cleanupSecret = Deno.env.get("CLEANUP_DISPATCH_SECRET")?.trim();
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();

  if (!token) {
    throw new Error("unauthorized: missing bearer");
  }

  const allowed = new Set<string>();
  if (cleanupSecret) allowed.add(cleanupSecret);
  if (serviceRole) allowed.add(serviceRole);

  if (allowed.size === 0) {
    throw new Error("unauthorized: server secrets not configured");
  }

  if (!allowed.has(token)) {
    throw new Error("unauthorized: invalid bearer");
  }
}

function createServiceClient(): ServiceClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("missing_supabase_env");
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as ServiceClient;
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

function isTrustedObjectKey(key: string): boolean {
  if (!key || key.length > 1024) return false;
  if (/^https?:\/\//i.test(key)) return false;
  if (key.includes("..") || key.startsWith("/") || key.includes("\\")) return false;
  // Upload path built by generate-upload-url: chats/{chatId}/...
  return /^chats\/[0-9a-f-]{36}\//i.test(key);
}

async function deleteYandexObject(input: {
  config: YandexConfig;
  key: string;
}): Promise<{ ok: boolean; status: number }> {
  const { config, key } = input;
  const host = `${config.bucket}.${config.endpoint}`;
  const now = new Date();
  const amzDate = toAmzDate(now);
  const dateStamp = amzDate.slice(0, 8);
  const credentialScope = `${dateStamp}/${config.region}/s3/aws4_request`;
  const canonicalUri = `/${encodeS3Key(key)}`;
  const signedHeaders = "host";
  const canonicalHeaders = `host:${host}\n`;
  const canonicalRequest = [
    "DELETE",
    canonicalUri,
    "",
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
  const authorization = [
    `AWS4-HMAC-SHA256 Credential=${config.accessKeyId}/${credentialScope}`,
    `SignedHeaders=${signedHeaders}`,
    `Signature=${signature}`,
  ].join(", ");

  const res = await fetch(`https://${host}${canonicalUri}`, {
    method: "DELETE",
    headers: {
      Host: host,
      "X-Amz-Date": amzDate,
      "X-Amz-Content-Sha256": "UNSIGNED-PAYLOAD",
      Authorization: authorization,
    },
  });

  return { ok: res.ok, status: res.status };
}

function backoffSeconds(attempts: number): number {
  const n = Math.max(1, attempts);
  return Math.min(3600, 30 * (2 ** Math.min(n - 1, 6)));
}

function sanitizeLogMessage(message: string): string {
  return message
    .replace(/https?:\/\/\S+/gi, "[redacted_url]")
    .replace(/(authorization|secret|password|access[_-]?key|signature)[=:]\S+/gi, "$1=[redacted]")
    .slice(0, 500);
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function normalizeEndpoint(value: string): string {
  return value.replace(/^https?:\/\//i, "").replace(/\/+$/g, "");
}

function encodeS3Key(key: string): string {
  return key.split("/").map((part) => encodeURIComponent(part)).join("/");
}

function toAmzDate(date: Date): string {
  return date.toISOString().replace(/[:-]|\.\d{3}/g, "");
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToHex(new Uint8Array(digest));
}

async function hmac(key: Uint8Array, value: string): Promise<Uint8Array> {
  // Copy into a fresh ArrayBuffer-backed view for Deno/TS BufferSource typing.
  const keyBytes = Uint8Array.from(key);
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
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

async function getSignatureKey(
  secret: string,
  dateStamp: string,
  region: string,
  service: string,
): Promise<Uint8Array> {
  const kDate = await hmac(new TextEncoder().encode(`AWS4${secret}`), dateStamp);
  const kRegion = await hmac(kDate, region);
  const kService = await hmac(kRegion, service);
  return await hmac(kService, "aws4_request");
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
