import 'dart:async';

/// Loads the chat independently, but never races cached and fresh assignments.
Future<void> runTeamInitialLoad({
  required bool Function() isClosed,
  required Future<void> Function() restoreAssignments,
  required Future<String?> Function() resolveChat,
  required Future<void> Function(String?) hydrateChat,
  required void Function(String?) startChat,
  required void Function() startRole,
  required void Function() subscribeChat,
  required void Function() startAssignments,
  required void Function() subscribeAssignments,
}) async {
  // Attach the error handler immediately: chat setup may finish much later.
  final restored = Future<void>.sync(restoreAssignments).catchError((_) {});
  final chatId = await resolveChat();
  if (isClosed()) return;
  await hydrateChat(chatId);
  if (isClosed()) return;
  startChat(chatId);
  startRole();
  subscribeChat();
  await restored;
  if (isClosed()) return;
  startAssignments();
  subscribeAssignments();
}
