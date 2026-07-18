import 'package:student_platform/src/utils/safe_debug_log.dart';

/// Chat list warm-up helper.
///
/// Intentionally does **not** preload full message histories. The chats list
/// already receives last message / unread via `get_my_chat_summaries`.
/// Message history is loaded only when the user opens a chat.
class ChatPreloadService {
  ChatPreloadService._();

  @Deprecated(
      'Message history preload removed; summaries are enough for list UI.')
  static void scheduleWarmUpFromServer({
    Duration delay = const Duration(milliseconds: 900),
    int limit = 12,
    int parallel = 2,
  }) {
    safeDebugLog(
      '[ChatPreload] scheduleWarmUpFromServer ignored (history preload disabled)',
    );
  }

  @Deprecated(
      'Message history preload removed; summaries are enough for list UI.')
  static Future<void> warmUpFromServer({
    int limit = 12,
    int parallel = 2,
  }) async {
    safeDebugLog(
      '[ChatPreload] warmUpFromServer ignored (history preload disabled)',
    );
  }

  /// No-op: do not fetch message histories for chat list entries.
  @Deprecated('Message history preload removed; open chat to load messages.')
  static Future<void> warmUpChatIds(
    Iterable<String?> chatIds, {
    int limit = 12,
    int parallel = 2,
  }) async {
    safeDebugLog(
      '[ChatPreload] warmUpChatIds ignored (history preload disabled)',
    );
  }
}
