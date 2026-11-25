const allowedPushDataKeys = new Set([
  "version",
  "type",
  "notification_id",
  "chat_id",
  "assignment_id",
  "team_id",
  "selection_id",
  "collection_id",
  "card_message_id",
  "message_id",
  "title",
  "body",
]);

export function visiblePushData(input: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(input)) {
    if (!allowedPushDataKeys.has(key) || value === null || value === undefined) continue;
    out[key] = typeof value === "string" ? value : String(value);
  }
  return out;
}

type VisibleNotification = {
  title: string;
  body: string;
  data: Record<string, string>;
  channelId: string;
};

export function visibleMessage(
  token: string,
  visible: VisibleNotification,
  recipient: string,
  id: string | null,
) {
  return {
    token,
    notification: { title: visible.title, body: visible.body },
    data: id ? { ...visible.data, recipient_id: recipient, notification_id: id } : visible.data,
    android: {
      priority: "HIGH",
      ttl: "2419200s",
      notification: {
        channel_id: visible.channelId,
        sound: "default",
        ...(id ? { tag: `student:${recipient}:${id}`, proxy: "DENY" } : {}),
      },
    },
    apns: { payload: { aps: { sound: "default", badge: 1 } } },
  };
}

export function androidReadMessage(token: string, recipient: string, id: string) {
  return {
    token,
    data: {
      type: "notification_read",
      version: "1",
      student_sync_action: "dismiss_v1",
      recipient_id: recipient,
      notification_id: id,
    },
    android: { priority: "NORMAL", ttl: "2419200s" },
  };
}
