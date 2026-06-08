// FILE: lib/src/ui/chats/data/dm_api.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';

class DmApi {
  static final SupabaseClient _sb = Supabase.instance.client;

  // 1) Создать/вернуть chat_id ЛС
  static Future<String> getOrCreateChatId({required String peerId}) async {
    final res = await _sb.rpc('ensure_dm_chat', params: {'p_partner': peerId});
    return (res ?? '').toString();
  }

  // 2) Загрузить сообщения (и подтянуть вложения)
  static Future<List<Message>> loadMessages({required String chatId, int limit = 50, DateTime? since}) async {
    final res = await _sb.rpc('get_chat_messages', params: {
      'p_chat_id': chatId,
      'p_limit': limit,
      'p_since': (since ?? DateTime.fromMillisecondsSinceEpoch(0)).toIso8601String(),
    });
    final rows = (res is List)
        ? res
        : (res == null ? <dynamic>[] : <dynamic>[res]);
    if (kDebugMode) {
      debugPrint('[DM] loadMessages chat=$chatId rows=${rows.length}');
    }

    final msgs = rows
        .map((e) => _messageFromRow(Map<String, dynamic>.from(e as Map), chatId: chatId))
        .toList();

    final ids = msgs.map((m) => m.id).toList();
    if (ids.isNotEmpty) {
      final byMsg = await _loadFilesByMessage(ids);
      for (var i = 0; i < msgs.length; i++) {
        final m = msgs[i];
        msgs[i] = m.copyWith(attachments: byMsg[m.id] ?? const []);
      }
    }

    return msgs;
  }

  static Message _messageFromRow(Map<String, dynamic> m, {required String chatId}) {
    return Message(
      id: (m['id'] ?? '').toString(),
      chatId: (m['chat_id'] ?? chatId).toString(),
      authorId: (m['author_id'] ?? '').toString(),
      authorLogin: (m['author_login'] ?? '').toString(),
      authorName: (m['author_name'] ?? 'Студент').toString(),
      authorAvatarUrl: (m['author_avatar_url'] ?? '').toString(),
      text: (m['text'] ?? m['content'] ?? m['body'] ?? '').toString(),
      type: _typeFromServer((m['type'] ?? m['msg_type'] ?? 'text').toString()),
      at: DateTime.tryParse((m['at'] ?? m['created_at'] ?? '').toString()) ?? DateTime.now(),
      replyToId: (m['reply_to_id']?.toString().isNotEmpty ?? false) ? m['reply_to_id'].toString() : null,
      attachments: const [],
      reactions: (m['reactions'] is Map) ? Map<String, int>.from(m['reactions']) : null,
    );
  }

  static Future<Map<String, List<ChatFile>>> _loadFilesByMessage(List<String> messageIds) async {
    final filesRows = await _sb
        .from('chat_files')
        .select('*')
        .inFilter('message_id', messageIds);
    final byMsg = <String, List<ChatFile>>{};
    for (final r in (filesRows as List)) {
      final m = Map<String, dynamic>.from(r as Map);
      final f = ChatFile.fromJson(m);
      final mid = (m['message_id'] ?? '').toString();
      byMsg.putIfAbsent(mid, () => []).add(f);
    }
    return byMsg;
  }

  static Future<void> _hydrateAuthor(Map<String, dynamic> data) async {
    final authorId = (data['author_id'] ?? '').toString();
    if (authorId.isEmpty) return;
    try {
      final user = await _sb
          .from('users')
          .select('login,name,surname,avatar_url')
          .eq('id', authorId)
          .maybeSingle();
      if (user == null) return;
      final u = Map<String, dynamic>.from(user as Map);
      final fullName = [
        (u['name'] ?? '').toString(),
        (u['surname'] ?? '').toString(),
      ].where((s) => s.isNotEmpty).join(' ').trim();
      data['author_login'] = (u['login'] ?? '').toString();
      if (fullName.isNotEmpty) data['author_name'] = fullName;
      data['author_avatar_url'] = (u['avatar_url'] ?? '').toString();
    } catch (_) {}
  }

  static Future<Message?> loadMessageById({
    required String chatId,
    required String messageId,
  }) async {
    try {
      final row = await _sb
          .from('messages')
          .select('*')
          .eq('chat_id', chatId)
          .eq('id', messageId)
          .maybeSingle();
      if (row == null) return null;

      final data = Map<String, dynamic>.from(row as Map);
      await _hydrateAuthor(data);

      final files = await _loadFilesByMessage([messageId]);
      return _messageFromRow(data, chatId: chatId).copyWith(
        attachments: files[messageId] ?? const [],
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DM] loadMessageById failed: $e');
      }
      return null;
    }
  }

  // 3) Realtime подписка по chat_id
  static Stream<List<Message>> watchMessages({required String chatId}) {
    final ctrl = StreamController<List<Message>>.broadcast();
    final current = <Message>[];

    String idFromPayload(PostgresChangePayload payload, {bool old = false}) {
      final record = old ? payload.oldRecord : payload.newRecord;
      return (record['id'] ?? '').toString();
    }

    Future<void> emitInitial() async {
      try {
        final list = await loadMessages(chatId: chatId);
        current
          ..clear()
          ..addAll(list);
        if (!ctrl.isClosed) ctrl.add(List<Message>.unmodifiable(current));
      } catch (_) {}
    }

    Future<void> insertOne(PostgresChangePayload payload) async {
      final id = idFromPayload(payload);
      if (id.isEmpty || current.any((m) => m.id == id)) return;
      final message = await loadMessageById(chatId: chatId, messageId: id);
      if (message == null) return;
      current.add(message);
      if (!ctrl.isClosed) ctrl.add(List<Message>.unmodifiable(current));
    }

    Future<void> updateOne(PostgresChangePayload payload) async {
      final id = idFromPayload(payload);
      if (id.isEmpty) return;
      final idx = current.indexWhere((m) => m.id == id);
      if (idx == -1) return;
      final message = await loadMessageById(chatId: chatId, messageId: id);
      if (message == null) return;
      current[idx] = message;
      if (!ctrl.isClosed) ctrl.add(List<Message>.unmodifiable(current));
    }

    void deleteOne(PostgresChangePayload payload) {
      final id = idFromPayload(payload, old: true);
      if (id.isEmpty) return;
      final before = current.length;
      current.removeWhere((m) => m.id == id);
      if (before != current.length && !ctrl.isClosed) {
        ctrl.add(List<Message>.unmodifiable(current));
      }
    }

    emitInitial();

    final ch = _sb.channel('dm:messages:$chatId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'chat_id',
          value: chatId,
        ),
        callback: (payload) => insertOne(payload),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'chat_id',
          value: chatId,
        ),
        callback: (payload) => updateOne(payload),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'chat_id',
          value: chatId,
        ),
        callback: deleteOne,
      )
      ..subscribe();

    ctrl.onCancel = () async {
      try { await ch.unsubscribe(); } catch (_) {}
    };

    return ctrl.stream;
  }

  // 4) Отправка текста + привязка файлов
  static Future<String> sendText({
    required String chatId,
    required String text,
    String? replyToId,
    List<String>? fileIds,
  }) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) {
      throw Exception('Not authenticated');
    }
    final hasFiles = (fileIds != null && fileIds.isNotEmpty);

    // Try RPC first (if present on server)
    try {
      final res = await _sb.rpc('send_message_in_chat_with_files', params: {
        'p_chat_id': chatId,
        'p_text': text,
        'p_reply_to': replyToId,
        'p_file_ids': hasFiles ? fileIds : <String>[],
      });
      if (res is Map && res['id'] != null) return res['id'].toString();
      if (res is String && res.isNotEmpty) return res;
      if (res is List && res.isNotEmpty) {
        final m = Map<String, dynamic>.from(res.first as Map);
        if (m['id'] != null) return m['id'].toString();
      }
    } catch (_) {
      // fallback below
    }

    // Fallback: direct insert with author_id
    final inserted = await _sb
        .from('messages')
        .insert({
          'chat_id': chatId,
          'author_id': uid,
          'content': text,
          'body': text,
          'msg_type': hasFiles ? 'file' : 'text',
          'reply_to_id': replyToId,
          'attachments': <dynamic>[],
          'reactions': <String, int>{},
        })
        .select('id')
        .single();

    final mid = Map<String, dynamic>.from(inserted as Map)['id'].toString();
    if (kDebugMode) {
      debugPrint('[DM] sent mid=$mid (files=${fileIds?.length ?? 0})');
    }

    if (hasFiles) {
      await _sb
          .from('chat_files')
          .update({'message_id': mid})
          .inFilter('id', fileIds)
          .eq('chat_id', chatId);
    }

    return mid;
  }

  // 5) Прочитано до сообщения
  static Future<void> markRead({required String chatId, required String messageId}) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return;
    await _sb
        .from('chat_reads')
        .upsert({
          'chat_id': chatId,
          'user_id': uid,
          'last_message_id': messageId,
          'seen_at': DateTime.now().toIso8601String(),
        }, onConflict: 'chat_id,user_id');
  }

  // 6) Метаданные непрочитанного
  static Future<Map<String, dynamic>> getUnreadMeta(String chatId) async {
    final res = await _sb.rpc('get_unread_in_chat', params: {'p_chat_id': chatId});
    if (res == null) return {'unread_count': 0, 'first_unread_id': null};
    if (res is List && res.isNotEmpty) {
      final m = Map<String, dynamic>.from(res.first as Map);
      return {
        'unread_count': (m['unread_count'] ?? 0) as int,
        'first_unread_id': (m['first_unread_id'] as String?)
      };
    }
    if (res is Map) {
      final m = Map<String, dynamic>.from(res);
      return {
        'unread_count': (m['unread_count'] ?? 0) as int,
        'first_unread_id': (m['first_unread_id'] as String?)
      };
    }
    return {'unread_count': 0, 'first_unread_id': null};
  }

  // 7) Реакции
  static Future<void> toggleReaction(String messageId, String emoji) async {
    await _sb.rpc('toggle_message_reaction', params: {
      'p_message_id': messageId,
      'p_emoji': emoji,
    });
  }

  // 8) Пин/удаление
  static Future<void> pinMessage(String messageId, bool pin) async {
    await _sb.from('messages').update({'is_pinned': pin}).eq('id', messageId);
  }

  static Future<void> deleteMessage(String messageId) async {
    await _sb.from('messages').delete().eq('id', messageId);
  }

  // 9) Upload: у нас уже есть FileService через ChatAttachmentsController
  static Future<String> upload(LocalAttach local, String chatId) async {
    // В текущей архитектуре загрузка делается через ChatAttachmentsController
    // Этот метод не используется напрямую из UI и может быть не нужен.
    throw UnimplementedError('Use ChatAttachmentsController.upload instead');
  }

  static MessageType _typeFromServer(String? s) {
    switch (s) {
      case 'assignmentDraft':
        return MessageType.assignmentDraft;
      case 'assignmentPublished':
        return MessageType.assignmentPublished;
      case 'file':
        return MessageType.file;
      default:
        return MessageType.text;
    }
  }

  static Future<ChatFile?> getFile(String fileId) async {
    try {
      final row = await _sb.from('chat_files').select('*').eq('id', fileId).maybeSingle();
      if (row == null) return null;
      return ChatFile.fromJson(Map<String, dynamic>.from(row as Map));
    } catch (_) {
      return null;
    }
  }
}
