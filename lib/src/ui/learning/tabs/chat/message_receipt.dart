/// Delivery / read ticks next to message time.
///
/// - `null` — legacy team/group behavior (single ✓ for own messages)
/// - `0` — no ticks (e.g. still sending / failed)
/// - `1` — delivered (saved on server)
/// - `2` — read by peer (`peer.last_read_at >= message.created_at`)
int? dmReceiptTicks({
  required bool isMine,
  required bool enableDmReceipts,
  required DateTime messageAt,
  DateTime? peerLastReadAt,
  required bool isSending,
  required bool isFailed,
}) {
  if (!enableDmReceipts || !isMine) return null;
  if (isSending || isFailed) return 0;
  final peer = peerLastReadAt?.toUtc();
  if (peer != null && !peer.isBefore(messageAt.toUtc())) {
    return 2;
  }
  return 1;
}

String formatMessageTimeLabel({
  required String time,
  required bool isMe,
  int? receiptTicks,
  bool isEdited = false,
}) {
  final labeled = isEdited ? 'изм. $time' : time;
  if (!isMe) return labeled;
  final ticks = receiptTicks ?? 1;
  if (ticks <= 0) return labeled;
  if (ticks >= 2) return '$labeled ✓✓';
  return '$labeled ✓';
}
