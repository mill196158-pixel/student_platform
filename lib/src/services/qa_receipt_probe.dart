import 'dart:io';

/// An experimental probe. A pending marker is never interpreted here: the
/// caller must fall back to the original receipt path under the same queue.
enum QaReceiptProbeResult { allowed, denied, pending }

QaReceiptProbeResult qaReceiptProbeSync(String path, String sid,
    {void Function(String)? debugStage}) {
  try {
    final pending = FileSystemEntity.typeSync('$path.pending', followLinks: false);
    debugStage?.call('pending_checked');
    if (pending != FileSystemEntityType.notFound) return QaReceiptProbeResult.pending;
    final denied = FileSystemEntity.typeSync('$path.denied', followLinks: false);
    debugStage?.call('denied_checked');
    if (denied != FileSystemEntityType.notFound) return QaReceiptProbeResult.denied;
    final proof = File('$path.grant').readAsStringSync();
    debugStage?.call('proof_read');
    if (proof != 'chat-file-grant-v2:$sid') return QaReceiptProbeResult.denied;
    final length = File(path).lengthSync();
    debugStage?.call('length_checked');
    return length > 0 ? QaReceiptProbeResult.allowed : QaReceiptProbeResult.denied;
  } catch (_) {
    return QaReceiptProbeResult.denied;
  }
}
