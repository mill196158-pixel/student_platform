import '../../learning/models/local_attach.dart';

/// Only a marker for a terminal (sent or explicitly canceled) operation may be
/// removed from a draft.
/// Legacy markers and unrelated attachments remain untouched.
bool isTerminalForwardSentinel(LocalAttach file, Set<String> terminalOperations) {
  const prefix = 'durable-forward:';
  if (file.path != '__FG__' || !file.localId.startsWith(prefix)) return false;
  final operation = file.localId.substring(prefix.length);
  return operation.isNotEmpty && terminalOperations.contains(operation);
}
