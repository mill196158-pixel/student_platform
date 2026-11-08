import 'dart:async';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';

/// QA-only handoff orchestration. Native remains the authority for source,
/// request reservation, OS dispatch and durable uncertainty.
enum QaDocumentOpenOutcome { started, blocked, uncertain }

Future<QaDocumentOpenOutcome> qaOpenDocument({
  required Future<SourceAttachmentIdentity> Function() prepare,
  required Future<String> Function(SourceAttachmentIdentity) dispatch,
  required Future<bool> Function() acknowledge,
  required bool Function() current,
  Duration timeout=const Duration(seconds:15),
}) async {
  SourceAttachmentIdentity source;
  try {
    source=await prepare().timeout(timeout);
    if (!current() || !source.valid) return QaDocumentOpenOutcome.blocked;
  } catch (_) { return QaDocumentOpenOutcome.blocked; }
  String result;
  try { result=await dispatch(source).timeout(timeout); }
  catch (_) { return QaDocumentOpenOutcome.uncertain; }
  if (result=='blocked') return QaDocumentOpenOutcome.blocked;
  if (result!='started') return QaDocumentOpenOutcome.uncertain;
  // The native reservation remains uncertain if acknowledgement fails.
  try { await acknowledge().timeout(const Duration(seconds:2)); } catch (_) {}
  return QaDocumentOpenOutcome.started;
}
