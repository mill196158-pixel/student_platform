// FILE: lib/src/ui/chats/core/dm_chat_service.dart
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import '../data/dm_api.dart';
import 'chat_message_memory_cache.dart';
import 'i_chat_service.dart';

class DmChatService implements IChatService {
  final String peerId;
  String? _chatId;

  DmChatService({required this.peerId});

  @override
  ChatMode get mode => ChatMode.dm;

  @override
  bool get supportsAssignments => false;

  @override
  bool get supportsNotes => false; // по ТЗ “заметки” не нужны в ЛС

  @override
  String get currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  String? get chatId => _chatId;

  @override
  Future<String> ensureChatId() async {
    if (_chatId != null && _chatId!.isNotEmpty) return _chatId!;
    _chatId = await DmApi.getOrCreateChatId(peerId: peerId);
    return _chatId!;
  }

  @override
  Stream<List<Message>> watchMessages() async* {
    final cid = await ensureChatId();
    final cached = ChatMessageMemoryCache.snapshot(cid);
    if (cached.isNotEmpty) {
      _cache
        ..clear()
        ..addAll(cached);
      yield cached;
    }

    await for (final list in DmApi.watchMessages(chatId: cid)) {
      _cache
        ..clear()
        ..addAll(list);
      yield list;
    }
  }

  @override
  List<Message> get currentMessages =>
      _chatId == null ? _cache : ChatMessageMemoryCache.snapshot(_chatId!);
  final List<Message> _cache = <Message>[]; // можно наполнять из watchMessages

  @override
  Future<List<Message>> loadOlderMessages(
      {required Message before, int limit = 50}) async {
    final cid = await ensureChatId();
    return DmApi.loadOlderMessages(chatId: cid, before: before, limit: limit);
  }

  @override
  Future<Map<String, dynamic>> getUnreadMeta() async {
    final sb = Supabase.instance.client;
    final chatId = await ensureChatId();
    try {
      final res =
          await sb.rpc('get_unread_meta', params: {'p_chat_id': chatId});
      final m = (res is List && res.isNotEmpty)
          ? Map<String, dynamic>.from(res.first as Map)
          : (res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{});
      return {
        'unread_count': m['unread_count'] ?? 0,
        'first_unread_id': m['first_unread_id'],
        'last_read_at': m['last_read_at'],
      };
    } catch (_) {
      // Фоллбэк на старую функцию + last_read_at из chat_reads
      final r1 =
          await sb.rpc('get_unread_in_chat', params: {'p_chat_id': chatId});
      int unread = 0;
      String? first;
      if (r1 is List && r1.isNotEmpty) {
        final mm = Map<String, dynamic>.from(r1.first as Map);
        unread = (mm['unread_count'] ?? 0) as int;
        first = (mm['first_unread_id'] as String?);
      } else if (r1 is Map) {
        final mm = Map<String, dynamic>.from(r1);
        unread = (mm['unread_count'] ?? 0) as int;
        first = (mm['first_unread_id'] as String?);
      }
      final r2 = await sb
          .from('chat_reads')
          .select('last_read_at')
          .eq('chat_id', chatId)
          .eq('user_id', sb.auth.currentUser!.id)
          .maybeSingle();
      return {
        'unread_count': unread,
        'first_unread_id': first,
        'last_read_at': r2?['last_read_at'],
      };
    }
  }

  @override
  Future<void> markRead(String lastMessageId) async {
    final sb = Supabase.instance.client;
    final chatId = await ensureChatId();
    if (chatId.isEmpty) return;
    await sb.rpc('mark_chat_read', params: {
      'p_chat_id': chatId,
      'p_message_id': lastMessageId,
    });
  }

  @override
  Future<String> sendText(String text,
      {String? replyToId, List<String>? fileIds}) async {
    final cid = await ensureChatId();
    return DmApi.sendText(
        chatId: cid, text: text, replyToId: replyToId, fileIds: fileIds);
  }

  @override
  Future<void> toggleReaction(String messageId, String emoji) =>
      DmApi.toggleReaction(messageId, emoji);

  @override
  Future<void> pinMessage(String messageId, bool pin) =>
      DmApi.pinMessage(messageId, pin);

  @override
  Future<void> deleteMessage(String messageId) =>
      DmApi.deleteMessage(messageId);

  @override
  Future<String> upload(LocalAttach local) async {
    final cid = await ensureChatId();
    return DmApi.upload(local, cid);
  }

  @override
  Future<ChatFile?> getFile(String fileId) => DmApi.getFile(fileId);
}
