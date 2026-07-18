import { createClient } from "npm:@supabase/supabase-js@2";
import { SignJWT, importPKCS8 } from "npm:jose@5.9.6";

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
};

type OutboxRow = {
  id: string;
  recipient_id: string;
  event_type: string;
  payload: Record<string, unknown>;
  attempts: number;
  app_notification_id: string | null;
};

type DeviceToken = {
  id: string;
  token: string;
  platform: string;
  installation_id: string;
};

type DeliveryDecision = {
  allow: boolean;
  reason?: string | null;
  show_message_preview?: boolean;
  title?: string;
  body?: string;
  data?: Record<string, unknown>;
  event_type?: string;
  recipient_id?: string;
  notification_id?: string;
};

const maxBatch = 25;
const fcmScope = "https://www.googleapis.com/auth/firebase.messaging";

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
    const serviceAccount = readServiceAccount();
    const accessToken = await getGoogleAccessToken(serviceAccount);

    const { data: claimed, error: claimError } = await supabase.rpc(
      "claim_pending_notification_outbox",
      { p_limit: maxBatch },
    );

    if (claimError) {
      throw new Error(`claim_failed: ${claimError.message}`);
    }

    const rows = (claimed ?? []) as OutboxRow[];
    let sent = 0;
    let skipped = 0;
    let failed = 0;

    for (const row of rows) {
      try {
        const result = await processOutboxRow({
          supabase,
          row,
          accessToken,
          projectId: serviceAccount.project_id,
        });
        if (result === "sent") sent += 1;
        else if (result === "skipped") skipped += 1;
        else failed += 1;
      } catch (error) {
        failed += 1;
        const message = error instanceof Error ? error.message : String(error);
        await supabase.rpc("complete_notification_outbox", {
          p_outbox_id: row.id,
          p_status: row.attempts >= 8 ? "failed" : "pending",
          p_error: message.slice(0, 500),
          p_retry_seconds: backoffSeconds(row.attempts),
        });
      }
    }

    return jsonResponse({
      ok: true,
      claimed: rows.length,
      sent,
      skipped,
      failed,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.startsWith("unauthorized") ? 401 : 500;
    return jsonResponse({ error: message }, status);
  }
});

function assertTrustedCaller(req: Request): void {
  const dispatchSecret = Deno.env.get("PUSH_DISPATCH_SECRET")?.trim();
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();

  if (!token) {
    throw new Error("unauthorized: missing bearer");
  }

  const allowed = new Set<string>();
  if (dispatchSecret) allowed.add(dispatchSecret);
  if (serviceRole) allowed.add(serviceRole);

  if (allowed.size === 0) {
    throw new Error("unauthorized: server secrets not configured");
  }

  if (!allowed.has(token)) {
    throw new Error("unauthorized: invalid bearer");
  }
}

function createServiceClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("missing_supabase_env");
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function readServiceAccount(): ServiceAccount {
  const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
  if (!raw) {
    throw new Error("missing_FIREBASE_SERVICE_ACCOUNT_JSON");
  }

  let parsed: ServiceAccount;
  try {
    parsed = JSON.parse(raw) as ServiceAccount;
  } catch {
    throw new Error("invalid_FIREBASE_SERVICE_ACCOUNT_JSON");
  }

  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    throw new Error("incomplete_FIREBASE_SERVICE_ACCOUNT_JSON");
  }

  return parsed;
}

async function getGoogleAccessToken(sa: ServiceAccount): Promise<string> {
  const pem = sa.private_key.replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const jwt = await new SignJWT({ scope: fcmScope })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience(sa.token_uri ?? "https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion: jwt,
  });

  const res = await fetch(sa.token_uri ?? "https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });

  const json = await res.json() as { access_token?: string; error?: string };
  if (!res.ok || !json.access_token) {
    throw new Error(`google_token_failed: ${json.error ?? res.status}`);
  }
  return json.access_token;
}

function resolvePushBody(decision: DeliveryDecision): string {
  const eventType = String(decision.event_type ?? "");
  const showPreview = decision.show_message_preview !== false;

  if (!showPreview) {
    if (eventType === "dm_message") {
      return "Новое сообщение";
    }
    if (eventType === "team_message" || eventType === "team_reply") {
      return "Новое сообщение в учебном чате";
    }
  }

  return String(decision.body ?? "");
}

async function processOutboxRow(args: {
  supabase: ReturnType<typeof createServiceClient>;
  row: OutboxRow;
  accessToken: string;
  projectId: string;
}): Promise<"sent" | "skipped" | "failed"> {
  const { supabase, row, accessToken, projectId } = args;

  const { data: decisionRaw, error: decisionError } = await supabase.rpc(
    "should_deliver_push_for_outbox",
    { p_outbox_id: row.id },
  );

  if (decisionError) {
    throw new Error(`decision_failed: ${decisionError.message}`);
  }

  const decision = decisionRaw as DeliveryDecision;
  if (!decision?.allow) {
    await supabase.rpc("complete_notification_outbox", {
      p_outbox_id: row.id,
      p_status: "skipped",
      p_error: decision?.reason ?? "filtered",
      p_retry_seconds: null,
    });
    return "skipped";
  }

  const { data: hadSuccessRaw, error: hadSuccessError } = await supabase.rpc(
    "has_successful_push_delivery",
    { p_outbox_id: row.id },
  );
  if (hadSuccessError) {
    throw new Error(`success_check_failed: ${hadSuccessError.message}`);
  }
  const hadPriorSuccess = hadSuccessRaw === true;

  const { data: tokensRaw, error: tokensError } = await supabase.rpc(
    "list_pending_device_push_tokens",
    {
      p_outbox_id: row.id,
      p_user_id: row.recipient_id,
    },
  );

  if (tokensError) {
    throw new Error(`tokens_failed: ${tokensError.message}`);
  }

  const tokens = (tokensRaw ?? []) as DeviceToken[];
  if (tokens.length === 0) {
    if (hadPriorSuccess) {
      await supabase.rpc("complete_notification_outbox", {
        p_outbox_id: row.id,
        p_status: "sent",
        p_error: null,
        p_retry_seconds: null,
      });
      return "sent";
    }

    await supabase.rpc("complete_notification_outbox", {
      p_outbox_id: row.id,
      p_status: "skipped",
      p_error: "no_tokens",
      p_retry_seconds: null,
    });
    return "skipped";
  }

  const pushBody = resolvePushBody(decision);
  const dataPayload = toStringMap({
    version: "1",
    type: String(decision.event_type ?? row.event_type),
    notification_id: String(decision.notification_id ?? row.app_notification_id ?? ""),
    ...(decision.data ?? {}),
  });

  const channelId = channelForEvent(String(decision.event_type ?? row.event_type));
  let successCount = 0;
  let permanentFailures = 0;
  let transientFailures = 0;

  for (const device of tokens) {
    try {
      const result = await sendFcmHttpV1({
        accessToken,
        projectId,
        token: device.token,
        title: String(decision.title ?? "Уведомление"),
        body: pushBody,
        data: dataPayload,
        channelId,
        platform: device.platform,
      });

      await supabase.rpc("record_push_delivery_attempt", {
        p_outbox_id: row.id,
        p_device_token_id: device.id,
        p_success: result.ok,
        p_http_status: result.httpStatus,
        p_error_code: result.errorCode,
        p_error_message: result.errorMessage,
      });

      if (result.ok) {
        successCount += 1;
        continue;
      }

      if (result.invalidateToken) {
        permanentFailures += 1;
        await supabase.rpc("invalidate_device_push_token_by_token", {
          p_token: device.token,
        });
      } else {
        transientFailures += 1;
      }
    } catch (error) {
      transientFailures += 1;
      const message = error instanceof Error ? error.message : String(error);
      await supabase.rpc("record_push_delivery_attempt", {
        p_outbox_id: row.id,
        p_device_token_id: device.id,
        p_success: false,
        p_http_status: null,
        p_error_code: "exception",
        p_error_message: message.slice(0, 500),
      });
    }
  }

  const hadSuccess = hadPriorSuccess || successCount > 0;

  // Any transient failure must retry remaining devices, even if another device succeeded.
  if (transientFailures > 0) {
    await supabase.rpc("complete_notification_outbox", {
      p_outbox_id: row.id,
      p_status: row.attempts >= 8 ? "failed" : "pending",
      p_error: "transient_fcm_failure",
      p_retry_seconds: backoffSeconds(row.attempts),
    });
    return "failed";
  }

  if (hadSuccess) {
    await supabase.rpc("complete_notification_outbox", {
      p_outbox_id: row.id,
      p_status: "sent",
      p_error: null,
      p_retry_seconds: null,
    });
    return "sent";
  }

  // No success anywhere; remaining devices were permanently invalid (or empty after invalidation).
  if (permanentFailures > 0) {
    await supabase.rpc("complete_notification_outbox", {
      p_outbox_id: row.id,
      p_status: "skipped",
      p_error: "all_tokens_invalid",
      p_retry_seconds: null,
    });
    return "skipped";
  }

  await supabase.rpc("complete_notification_outbox", {
    p_outbox_id: row.id,
    p_status: "skipped",
    p_error: "no_delivery",
    p_retry_seconds: null,
  });
  return "skipped";
}

async function sendFcmHttpV1(args: {
  accessToken: string;
  projectId: string;
  token: string;
  title: string;
  body: string;
  data: Record<string, string>;
  channelId: string;
  platform: string;
}): Promise<{
  ok: boolean;
  httpStatus: number;
  errorCode?: string;
  errorMessage?: string;
  invalidateToken: boolean;
}> {
  const url =
    `https://fcm.googleapis.com/v1/projects/${args.projectId}/messages:send`;

  const message: Record<string, unknown> = {
    token: args.token,
    data: args.data,
    notification: {
      title: args.title,
      body: args.body,
    },
    android: {
      priority: "HIGH",
      notification: {
        channel_id: args.channelId,
        sound: "default",
      },
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
          badge: 1,
        },
      },
    },
  };

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${args.accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ message }),
  });

  if (res.ok) {
    return { ok: true, httpStatus: res.status, invalidateToken: false };
  }

  let errorCode: string | undefined;
  let errorMessage: string | undefined;
  try {
    const json = await res.json() as {
      error?: { status?: string; message?: string; details?: Array<{ errorCode?: string }> };
    };
    errorCode = json.error?.details?.[0]?.errorCode ?? json.error?.status;
    errorMessage = json.error?.message;
  } catch {
    errorMessage = await res.text();
  }

  const permanent = isPermanentFcmError(errorCode, res.status);
  return {
    ok: false,
    httpStatus: res.status,
    errorCode,
    errorMessage: errorMessage?.slice(0, 500),
    invalidateToken: permanent,
  };
}

function isPermanentFcmError(errorCode: string | undefined, httpStatus: number): boolean {
  const code = (errorCode ?? "").toUpperCase();
  if (
    code.includes("UNREGISTERED") ||
    code.includes("INVALID_ARGUMENT") ||
    code.includes("NOT_FOUND") ||
    code.includes("SENDER_ID_MISMATCH")
  ) {
    return true;
  }
  return httpStatus === 404;
}

function channelForEvent(eventType: string): string {
  switch (eventType) {
    case "dm_message":
    case "team_message":
    case "team_reply":
      return "messages";
    case "friend_request":
    case "friend_accepted":
      return "social";
    case "assignment":
    case "schedule_change":
    case "announcement":
      return "study";
    default:
      return "messages";
  }
}

function toStringMap(input: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(input)) {
    if (value === null || value === undefined) continue;
    out[key] = typeof value === "string" ? value : String(value);
  }
  return out;
}

function backoffSeconds(attempts: number): number {
  const n = Math.max(1, attempts);
  return Math.min(3600, 15 * (2 ** Math.min(n, 6)));
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers":
        "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    },
  });
}
