import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

/// Compatibility facade over [ChatMessageCacheStore].
///
/// [has] is true for any found snapshot, including an empty message list.
class ChatMessageMemoryCache {
  ChatMessageMemoryCache._();

  static bool has(String chatId) => ChatMessageCacheStore.hasSnapshot(chatId);

  static bool hasSnapshot(String chatId) =>
      ChatMessageCacheStore.hasSnapshot(chatId);

  static List<Message> snapshot(String chatId) {
    return ChatMessageCacheStore.messagesSync(chatId);
  }

  static List<Message> replace(String chatId, Iterable<Message> messages) {
    // Fire-and-forget persist; memory is updated synchronously inside store.
    ChatMessageCacheStore.replace(chatId: chatId, messages: messages);
    return ChatMessageCacheStore.messagesSync(chatId);
  }

  static List<Message> merge(String chatId, Iterable<Message> messages) {
    ChatMessageCacheStore.merge(chatId: chatId, messages: messages);
    return ChatMessageCacheStore.messagesSync(chatId);
  }

  static List<Message> upsert(String chatId, Message message) {
    ChatMessageCacheStore.upsert(chatId, message);
    return ChatMessageCacheStore.messagesSync(chatId);
  }

  static List<Message> reconcileUpsert(
    String chatId,
    Message serverMessage, {
    String? clientId,
  }) {
    ChatMessageCacheStore.reconcileUpsert(
      chatId,
      serverMessage,
      clientId: clientId,
    );
    return ChatMessageCacheStore.messagesSync(chatId);
  }

  static List<Message> remove(String chatId, String messageId) {
    ChatMessageCacheStore.remove(chatId, messageId);
    return ChatMessageCacheStore.messagesSync(chatId);
  }

  /// Drop messages at/before personal clear boundary (hide/clear for me).
  static List<Message> pruneAtOrBefore(String chatId, DateTime? clearedAt) {
    ChatMessageCacheStore.pruneAtOrBefore(chatId, clearedAt);
    final snap = ChatMessageCacheStore.peek(chatId);
    if (!snap.found) return const <Message>[];
    return List<Message>.unmodifiable(snap.messages);
  }

  static void clearChat(String chatId) {
    ChatMessageCacheStore.clearChat(chatId);
  }

  static Future<void> clearAll() => ChatMessageCacheStore.clearOnLogout();
}
