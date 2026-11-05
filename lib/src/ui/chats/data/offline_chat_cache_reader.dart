import 'dart:convert';

import '../core/chat_message_cache_store.dart';
import '../core/chat_messages_load_state.dart';
import 'chat_summaries_cache.dart';

/// Local-only cache access. Admission and session lifetime must be enforced by
/// the caller; a user id alone is not proof of authorization.
class OfflineChatCacheReader {
  OfflineChatCacheReader({
    Future<String?> Function(String userId)? readSummaries,
    Future<ChatCacheSnapshot> Function(String chatId, String userId)?
        readMessages,
  })  : _readSummaries = readSummaries ?? ChatSummariesCache.read,
        _readMessages = readMessages ??
            ((chatId, userId) =>
                ChatMessageCacheStore.read(chatId, userId: userId));

  final Future<String?> Function(String userId) _readSummaries;
  final Future<ChatCacheSnapshot> Function(String chatId, String userId)
      _readMessages;

  Future<OfflineChatList> chats(String userId) async {
    final uid = _requiredId(userId);
    final raw = await _readSummaries(uid);
    if (raw == null || raw.isEmpty) {
      return const OfflineChatList(OfflineChatListState.missing, []);
    }
    try {
      final value = jsonDecode(raw);
      if (value is! List) throw const FormatException();
      final chats = <OfflineChatSummary>[];
      var damaged = false;
      for (final item in value) {
        if (item is! Map) {
          damaged = true;
          continue;
        }
        final id = item['chatId'];
        final title = item['title'];
        if (id is! String || id.trim().isEmpty || title is! String) {
          damaged = true;
          continue;
        }
        chats.add(OfflineChatSummary(id: id, title: title));
      }
      return OfflineChatList(OfflineChatListState.available, chats,
          partiallyDamaged: damaged);
    } on FormatException {
      return const OfflineChatList(OfflineChatListState.corrupt, []);
    }
  }

  Future<ChatCacheSnapshot> messages(String userId, String chatId) =>
      _readMessages(_requiredId(chatId), _requiredId(userId));

  static String _requiredId(String value) {
    final result = value.trim();
    if (result.isEmpty) throw ArgumentError('An explicit id is required');
    return result;
  }
}

enum OfflineChatListState { missing, available, corrupt }

class OfflineChatList {
  const OfflineChatList(this.state, this.chats,
      {this.partiallyDamaged = false});
  final OfflineChatListState state;
  final List<OfflineChatSummary> chats;
  final bool partiallyDamaged;
}

class OfflineChatSummary {
  const OfflineChatSummary({required this.id, required this.title});
  final String id;
  final String title;
}
