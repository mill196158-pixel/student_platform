import { androidReadMessage, visibleMessage, visiblePushData } from "./fcm_message.ts";
import assert from "node:assert/strict";

const alert = {
  title: "QA",
  body: "QA",
  data: { recipient_id: "incorrect", notification_id: "incorrect" },
  channelId: "messages",
};

Deno.test("the visible tag and data identify the same authoritative row", () => {
  const message = visibleMessage("device", alert, "recipient", "row");
  assert.equal(message.android.notification.tag, "student:recipient:row");
  assert.equal(message.android.notification.proxy, "DENY");
  assert.deepEqual(message.data, { recipient_id: "recipient", notification_id: "row" });
  assert.deepEqual(message.notification, { title: "QA", body: "QA" });
});

Deno.test("unlinked legacy rows retain Firebase's default notification tag", () => {
  const message = visibleMessage("device", { ...alert, data: {} }, "recipient", null);
  assert.equal(message.android.notification.tag, undefined);
  assert.deepEqual(message.data, {});
});

Deno.test("read receipts use a data-only message addressed to one installation", () => {
  assert.deepEqual(androidReadMessage("device", "recipient", "row"), {
    token: "device",
    android: { priority: "NORMAL", ttl: "2419200s" },
    data: {
      type: "notification_read", version: "1", student_sync_action: "dismiss_v1",
      recipient_id: "recipient", notification_id: "row",
    },
  });
});

Deno.test("an assignment notification retains its ID for the system click", () => {
  const data = visiblePushData({ type: "assignment", assignment_id: "task", version: 1, private_note: "internal" });
  const message = visibleMessage("device", { ...alert, data }, "student", "notice");
  assert.deepEqual(message.data, {
    type: "assignment", assignment_id: "task", version: "1", recipient_id: "student", notification_id: "notice",
  });
});
