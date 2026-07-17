import 'package:student_platform/src/ui/learning/models/message.dart';

class ChatMessageMemoryCache {
  ChatMessageMemoryCache._();

  static final Map<String, List<Message>> _messagesByChatId = {};

  static bool has(String chatId) =>
      _messagesByChatId[chatId]?.isNotEmpty == true;

  static List<Message> snapshot(String chatId) {
    return List<Message>.unmodifiable(
        _messagesByChatId[chatId] ?? const <Message>[]);
  }

  static List<Message> replace(String chatId, Iterable<Message> messages) {
    final next = _dedupeAndSort(messages);
    _messagesByChatId[chatId] = next;
    return List<Message>.unmodifiable(next);
  }

  static List<Message> merge(String chatId, Iterable<Message> messages) {
    final next = _dedupeAndSort([
      ...?_messagesByChatId[chatId],
      ...messages,
    ]);
    _messagesByChatId[chatId] = next;
    return List<Message>.unmodifiable(next);
  }

  static List<Message> upsert(String chatId, Message message) {
    return merge(chatId, [message]);
  }

  static List<Message> reconcileUpsert(
    String chatId,
    Message serverMessage, {
    String? clientId,
  }) {
    final current = List<Message>.from(_messagesByChatId[chatId] ?? const []);
    current.removeWhere((message) {
      if (!message.isLocal) return false;
      if (clientId != null && clientId.isNotEmpty) {
        return message.clientId == clientId || message.id == clientId;
      }
      return _isLikelySameLocalMessage(message, serverMessage);
    });
    current.add(
        serverMessage.copyWith(deliveryStatus: MessageDeliveryStatus.sent));
    final next = _dedupeAndSort(current);
    _messagesByChatId[chatId] = next;
    return List<Message>.unmodifiable(next);
  }

  static List<Message> remove(String chatId, String messageId) {
    final current = _messagesByChatId[chatId];
    if (current == null) return const <Message>[];

    final next = current.where((m) => m.id != messageId).toList();
    _messagesByChatId[chatId] = next;
    return List<Message>.unmodifiable(next);
  }

  /// Drop messages at/before personal clear boundary (hide/clear for me).
  static List<Message> pruneAtOrBefore(String chatId, DateTime? clearedAt) {
    if (clearedAt == null) {
      return snapshot(chatId);
    }
    final current = _messagesByChatId[chatId];
    if (current == null || current.isEmpty) return const <Message>[];

    final next = current.where((m) => m.at.isAfter(clearedAt)).toList();
    _messagesByChatId[chatId] = next;
    return List<Message>.unmodifiable(next);
  }

  static void clearChat(String chatId) {
    _messagesByChatId.remove(chatId);
  }

  static List<Message> _dedupeAndSort(Iterable<Message> messages) {
    final byId = <String, Message>{};
    for (final message in messages) {
      if (message.id.isEmpty) continue;
      if (!message.isLocal) {
        String? localDuplicateId;
        for (final entry in byId.entries) {
          if (_isLikelySameLocalMessage(entry.value, message)) {
            localDuplicateId = entry.key;
            break;
          }
        }
        if (localDuplicateId != null) {
          byId.remove(localDuplicateId);
        }
      }
      final previous = byId[message.id];
      byId[message.id] =
          previous == null ? message : _mergeSameMessage(previous, message);
    }

    final list = byId.values.toList()
      ..sort((a, b) {
        final byTime = a.at.compareTo(b.at);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return list;
  }

  static Message _mergeSameMessage(Message previous, Message incoming) {
    final previousName = previous.authorName.trim();
    final incomingName = incoming.authorName.trim();
    final shouldKeepPreviousName = previousName.isNotEmpty &&
        (incomingName.isEmpty ||
            incomingName == 'Студент' ||
            incomingName == 'Вы');
    final shouldKeepPreviousLogin = previous.authorLogin.trim().isNotEmpty &&
        incoming.authorLogin.trim().isEmpty;
    final shouldKeepPreviousAvatar = (incoming.authorAvatarUrl == null ||
            incoming.authorAvatarUrl!.isEmpty) &&
        previous.authorAvatarUrl != null &&
        previous.authorAvatarUrl!.isNotEmpty;

    return incoming.copyWith(
      authorLogin:
          shouldKeepPreviousLogin ? previous.authorLogin : incoming.authorLogin,
      authorName:
          shouldKeepPreviousName ? previous.authorName : incoming.authorName,
      authorAvatarUrl: shouldKeepPreviousAvatar
          ? previous.authorAvatarUrl
          : incoming.authorAvatarUrl,
      userReactions: incoming.userReactions ?? previous.userReactions,
    );
  }

  static bool _isLikelySameLocalMessage(Message local, Message server) {
    if (!local.isLocal || server.isLocal) return false;
    if (local.authorId.isNotEmpty &&
        server.authorId.isNotEmpty &&
        local.authorId != server.authorId) {
      return false;
    }
    if (local.text.trim() != server.text.trim()) return false;
    if ((local.replyToId ?? '') != (server.replyToId ?? '')) return false;
    if (local.type != server.type) return false;
    if (_attachmentsFingerprint(local) != _attachmentsFingerprint(server)) {
      return false;
    }

    final diff = local.at.difference(server.at).abs();
    return diff <= const Duration(seconds: 30);
  }

  static String _attachmentsFingerprint(Message message) {
    final attachments = message.attachments ?? const [];
    final ids = attachments
        .map((file) => file.id)
        .where((id) => id.isNotEmpty)
        .toList()
      ..sort();
    if (ids.isNotEmpty) return ids.join(',');
    return message.fileId ?? '';
  }
}
