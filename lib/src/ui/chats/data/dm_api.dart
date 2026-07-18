// FILE: lib/src/ui/chats/data/dm_api.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';
import '../core/chat_message_memory_cache.dart';
import 'blocks_api.dart';

class DmApi {
  static final SupabaseClient _sb = Supabase.instance.client;
  static final Map<String, List<Message>> _streamMessages = {};
  static final Map<String, StreamController<List<Message>>> _streamControllers =
      {};

  /// Per-chat clear boundary for the current user (one settings fetch).
  static final Map<String, DateTime?> _clearedAtByChat = {};

  // 1) Создать/вернуть chat_id ЛС
  static Future<String> getOrCreateChatId({required String peerId}) async {
    final res = await _sb.rpc('ensure_dm_chat', params: {'p_partner': peerId});
    return (res ?? '').toString();
  }

  /// One settings row for auth.uid() + chat. Null = never cleared.
  static Future<DateTime?> loadClearedAt(String chatId) async {
    if (_clearedAtByChat.containsKey(chatId)) {
      return _clearedAtByChat[chatId];
    }
    final me = _sb.auth.currentUser?.id;
    if (me == null || me.isEmpty || chatId.isEmpty) {
      _clearedAtByChat[chatId] = null;
      return null;
    }
    try {
      final row = await _sb
          .from('chat_user_settings')
          .select('cleared_at')
          .eq('user_id', me)
          .eq('chat_id', chatId)
          .maybeSingle();
      final cleared = row == null
          ? null
          : DateTime.tryParse((row['cleared_at'] ?? '').toString());
      _clearedAtByChat[chatId] = cleared;
      return cleared;
    } catch (_) {
      _clearedAtByChat[chatId] = null;
      return null;
    }
  }

  static void invalidateClearedAt(String chatId) {
    _clearedAtByChat.remove(chatId);
  }

  // 2) Загрузить сообщения (и подтянуть вложения)
  static Future<List<Message>> loadMessages({
    required String chatId,
    int limit = 50,
    DateTime? since,
    DateTime? clearedAt,
  }) async {
    final clearFloor = clearedAt ?? await loadClearedAt(chatId);
    ChatMessageMemoryCache.pruneAtOrBefore(chatId, clearFloor);

    var query = _sb.from('messages').select('*').eq('chat_id', chatId);

    final sinceAt = since ?? DateTime.fromMillisecondsSinceEpoch(0);
    // cleared_at: only messages with created_at > cleared_at.
    if (clearFloor != null && !sinceAt.isAfter(clearFloor)) {
      query = query.gt('created_at', clearFloor.toUtc().toIso8601String());
    } else {
      query = query.gte('created_at', sinceAt.toUtc().toIso8601String());
    }

    // Последние N сообщений (DESC), затем ASC для UI.
    final rows = await query.order('created_at', ascending: false).limit(limit);

    if (kDebugMode) {
      final boundary = clearFloor?.toUtc().toIso8601String() ?? '<none>';
      debugPrint(
        '[DM] loadMessages chat=${maskDebugId(chatId)} rows=${(rows as List).length} '
        'since=${sinceAt.toUtc().toIso8601String()} clearedAt=$boundary',
      );
    }

    final msgs = <Message>[];
    for (final row in (rows as List).reversed) {
      final data = Map<String, dynamic>.from(row as Map);
      await _hydrateAuthor(data);
      final message = _messageFromRow(data, chatId: chatId);
      if (clearFloor != null && !message.at.isAfter(clearFloor)) continue;
      msgs.add(message);
    }

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

  static Message _messageFromRow(Map<String, dynamic> m,
      {required String chatId}) {
    final authorName = (m['author_name'] ?? '').toString().trim();
    final authorLogin = (m['author_login'] ?? '').toString().trim();
    return Message(
      id: (m['id'] ?? '').toString(),
      chatId: (m['chat_id'] ?? chatId).toString(),
      authorId: (m['author_id'] ?? '').toString(),
      authorLogin: authorLogin,
      authorName: authorName.isNotEmpty
          ? authorName
          : (authorLogin.isNotEmpty ? authorLogin : 'Студент'),
      authorAvatarUrl: (m['author_avatar_url'] ?? '').toString(),
      text: (m['text'] ?? m['content'] ?? m['body'] ?? '').toString(),
      type: _typeFromServer((m['type'] ?? m['msg_type'] ?? 'text').toString()),
      at: DateTime.tryParse((m['at'] ?? m['created_at'] ?? '').toString()) ??
          DateTime.now(),
      editedAt:
          DateTime.tryParse((m['edited_at'] ?? m['editedAt'] ?? '').toString()),
      replyToId: (m['reply_to_id']?.toString().isNotEmpty ?? false)
          ? m['reply_to_id'].toString()
          : null,
      attachments: const [],
      reactions: (m['reactions'] is Map)
          ? Map<String, int>.from(m['reactions'])
          : null,
    );
  }

  static Future<Map<String, List<ChatFile>>> _loadFilesByMessage(
      List<String> messageIds) async {
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

    // Прямое чтение public.users работает только для собственного ряда
    // (RLS). Для чужих авторов имя приходит пустым и в UI подставляется
    // «Студент», поэтому дочитываем профиль через SECURITY DEFINER RPC.
    try {
      final user = await _sb
          .from('users')
          .select('login,name,surname,avatar_url')
          .eq('id', authorId)
          .maybeSingle();
      if (user != null) {
        final u = Map<String, dynamic>.from(user as Map);
        final fullName = [
          (u['name'] ?? '').toString(),
          (u['surname'] ?? '').toString(),
        ].where((s) => s.isNotEmpty).join(' ').trim();
        data['author_login'] = (u['login'] ?? '').toString();
        data['author_name'] =
            fullName.isNotEmpty ? fullName : (u['login'] ?? '').toString();
        data['author_avatar_url'] = (u['avatar_url'] ?? '').toString();
        return;
      }
    } catch (_) {}

    try {
      final res = await _sb.rpc('get_user_profile', params: {'p_id': authorId});
      Map<String, dynamic>? u;
      if (res is List && res.isNotEmpty) {
        u = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        u = Map<String, dynamic>.from(res);
      }
      if (u == null) return;
      final fullName = [
        (u['name'] ?? '').toString(),
        (u['surname'] ?? '').toString(),
      ].where((s) => s.trim().isNotEmpty).join(' ').trim();
      if (fullName.isNotEmpty) data['author_name'] = fullName;
      final avatar = (u['avatar_url'] ?? '').toString();
      if (avatar.isNotEmpty) data['author_avatar_url'] = avatar;
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

  static Future<List<Message>> loadOlderMessages({
    required String chatId,
    required Message before,
    int limit = 50,
  }) async {
    try {
      final clearedAt = await loadClearedAt(chatId);
      var query = _sb
          .from('messages')
          .select('*')
          .eq('chat_id', chatId)
          .lte('created_at', before.at.toUtc().toIso8601String());
      if (clearedAt != null) {
        query = query.gt('created_at', clearedAt.toUtc().toIso8601String());
      }
      final rows =
          await query.order('created_at', ascending: false).limit(limit + 1);

      final older = <Message>[];
      for (final row in rows as List) {
        final data = Map<String, dynamic>.from(row as Map);
        final id = (data['id'] ?? '').toString();
        if (id.isEmpty || id == before.id) continue;

        await _hydrateAuthor(data);
        final message = _messageFromRow(data, chatId: chatId);
        if (clearedAt != null && !message.at.isAfter(clearedAt)) continue;
        final files = await _loadFilesByMessage([id]);
        older.add(message.copyWith(
          attachments: files[id] ?? const [],
        ));
      }

      older.sort((a, b) => a.at.compareTo(b.at));
      final page = older.take(limit).toList();
      ChatMessageMemoryCache.merge(chatId, page);
      ChatMessageMemoryCache.pruneAtOrBefore(chatId, clearedAt);

      final current = _streamMessages[chatId];
      final ctrl = _streamControllers[chatId];
      if (current != null && ctrl != null) {
        final existingIds = current.map((m) => m.id).toSet();
        final unique = page.where((m) => existingIds.add(m.id)).toList();
        if (unique.isNotEmpty) {
          current.insertAll(0, unique);
          ChatMessageMemoryCache.merge(chatId, current);
          final visible =
              ChatMessageMemoryCache.pruneAtOrBefore(chatId, clearedAt);
          current
            ..clear()
            ..addAll(visible);
          if (!ctrl.isClosed) ctrl.add(List<Message>.unmodifiable(current));
        }
        return unique;
      }
      return page;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DM] loadOlderMessages failed: $e');
      }
      return [];
    }
  }

  static Future<void> _publishMessageById({
    required String chatId,
    required String messageId,
  }) async {
    if (messageId.isEmpty) return;

    final message = await loadMessageById(chatId: chatId, messageId: messageId);
    if (message == null) return;

    final merged = ChatMessageMemoryCache.reconcileUpsert(chatId, message);
    final current = _streamMessages[chatId];
    if (current != null) {
      current
        ..clear()
        ..addAll(merged);
    }

    final ctrl = _streamControllers[chatId];
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(List<Message>.unmodifiable(merged));
    }
  }

  static String _publishOptimisticMessage({
    required String chatId,
    required String userId,
    required String text,
    String? replyToId,
  }) {
    final clientId =
        'local_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999)}';
    final local = Message(
      id: clientId,
      chatId: chatId,
      authorId: userId,
      authorLogin: '',
      authorName: 'Вы',
      text: text,
      at: DateTime.now(),
      replyToId: replyToId,
      clientId: clientId,
      deliveryStatus: MessageDeliveryStatus.sending,
    );
    final merged = ChatMessageMemoryCache.upsert(chatId, local);
    final current = _streamMessages.putIfAbsent(chatId, () => <Message>[]);
    current
      ..clear()
      ..addAll(merged);
    final ctrl = _streamControllers[chatId];
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(List<Message>.unmodifiable(merged));
    }
    return clientId;
  }

  static void _markOptimisticFailed({
    required String chatId,
    required String clientId,
  }) {
    final current = ChatMessageMemoryCache.snapshot(chatId);
    if (current.isEmpty) return;
    final next = current.map((message) {
      if (message.clientId == clientId || message.id == clientId) {
        return message.copyWith(deliveryStatus: MessageDeliveryStatus.failed);
      }
      return message;
    }).toList();
    final merged = ChatMessageMemoryCache.replace(chatId, next);
    final streamCurrent = _streamMessages.putIfAbsent(chatId, () => <Message>[]);
    streamCurrent
      ..clear()
      ..addAll(merged);
    final ctrl = _streamControllers[chatId];
    if (ctrl != null && !ctrl.isClosed) {
      ctrl.add(List<Message>.unmodifiable(merged));
    }
  }

  static Future<List<Message>> refreshStream({required String chatId}) async {
    if (chatId.isEmpty) return const <Message>[];
    try {
      invalidateClearedAt(chatId);
      final clearedAt = await loadClearedAt(chatId);
      final list = await loadMessages(chatId: chatId, clearedAt: clearedAt);
      ChatMessageMemoryCache.merge(chatId, list);
      final visible = ChatMessageMemoryCache.pruneAtOrBefore(chatId, clearedAt);

      final current = _streamMessages.putIfAbsent(chatId, () => <Message>[]);
      current
        ..clear()
        ..addAll(visible);

      final ctrl = _streamControllers[chatId];
      if (ctrl != null && !ctrl.isClosed) {
        ctrl.add(List<Message>.unmodifiable(current));
      }
      return List<Message>.unmodifiable(current);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DM] refreshStream failed chat=${maskDebugId(chatId)}: $e');
      }
      return const <Message>[];
    }
  }

  // 3) Realtime подписка по chat_id
  static Stream<List<Message>> watchMessages({required String chatId}) {
    if (_streamControllers.containsKey(chatId)) {
      final ctrl = _streamControllers[chatId]!;
      final current = _streamMessages[chatId] ?? const <Message>[];
      unawaited(refreshStream(chatId: chatId));
      return Stream<List<Message>>.multi((controller) {
        if (current.isNotEmpty) {
          controller.add(List<Message>.unmodifiable(current));
        }
        final sub = ctrl.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      });
    }

    final ctrl = StreamController<List<Message>>.broadcast();
    final current = _streamMessages.putIfAbsent(chatId, () => <Message>[]);
    _streamControllers[chatId] = ctrl;

    String idFromPayload(PostgresChangePayload payload, {bool old = false}) {
      final record = old ? payload.oldRecord : payload.newRecord;
      return (record['id'] ?? '').toString();
    }

    Future<void> emitInitial() async {
      try {
        invalidateClearedAt(chatId);
        final clearedAt = await loadClearedAt(chatId);
        final prunedCache =
            ChatMessageMemoryCache.pruneAtOrBefore(chatId, clearedAt);
        if (prunedCache.isNotEmpty) {
          current
            ..clear()
            ..addAll(prunedCache);
          if (!ctrl.isClosed) ctrl.add(List<Message>.unmodifiable(current));
        }

        final list = await loadMessages(chatId: chatId, clearedAt: clearedAt);
        ChatMessageMemoryCache.merge(chatId, list);
        final visible =
            ChatMessageMemoryCache.pruneAtOrBefore(chatId, clearedAt);
        current
          ..clear()
          ..addAll(visible);
        if (!ctrl.isClosed) ctrl.add(List<Message>.unmodifiable(current));
      } catch (_) {}
    }

    Future<void> insertOne(PostgresChangePayload payload) async {
      final id = idFromPayload(payload);
      if (id.isEmpty || current.any((m) => m.id == id)) return;
      final clearedAt = await loadClearedAt(chatId);
      final message = await loadMessageById(chatId: chatId, messageId: id);
      if (message == null) return;
      if (clearedAt != null && !message.at.isAfter(clearedAt)) return;
      ChatMessageMemoryCache.reconcileUpsert(chatId, message);
      final visible = ChatMessageMemoryCache.pruneAtOrBefore(chatId, clearedAt);
      current
        ..clear()
        ..addAll(visible);
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
      final merged = ChatMessageMemoryCache.merge(chatId, current);
      current
        ..clear()
        ..addAll(merged);
      if (!ctrl.isClosed) ctrl.add(List<Message>.unmodifiable(current));
    }

    void deleteOne(PostgresChangePayload payload) {
      final id = idFromPayload(payload, old: true);
      if (id.isEmpty) return;
      final before = current.length;
      current.removeWhere((m) => m.id == id);
      ChatMessageMemoryCache.remove(chatId, id);
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
      try {
        await ch.unsubscribe();
      } catch (_) {}
      _streamControllers.remove(chatId);
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
    final optimisticId = hasFiles
        ? null
        : _publishOptimisticMessage(
            chatId: chatId,
            userId: uid,
            text: text,
            replyToId: replyToId,
          );

    // Try RPC first (if present on server)
    try {
      final res = await _sb.rpc('send_message_in_chat_with_files', params: {
        'p_chat_id': chatId,
        'p_text': text,
        'p_reply_to': replyToId,
        'p_file_ids': hasFiles ? fileIds : <String>[],
      });
      if (res is Map && res['id'] != null) {
        final id = res['id'].toString();
        await _publishMessageById(chatId: chatId, messageId: id);
        return id;
      }
      if (res is String && res.isNotEmpty) {
        await _publishMessageById(chatId: chatId, messageId: res);
        return res;
      }
      if (res is List && res.isNotEmpty) {
        final m = Map<String, dynamic>.from(res.first as Map);
        if (m['id'] != null) {
          final id = m['id'].toString();
          await _publishMessageById(chatId: chatId, messageId: id);
          return id;
        }
      }
    } catch (e) {
      if (BlocksApi.isDmBlockedError(e)) {
        if (optimisticId != null) {
          _markOptimisticFailed(chatId: chatId, clientId: optimisticId);
        }
        rethrow;
      }
      // fallback below
    }

    // Fallback: direct insert with author_id
    late final dynamic inserted;
    try {
      inserted = await _sb
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
    } catch (_) {
      if (optimisticId != null) {
        _markOptimisticFailed(chatId: chatId, clientId: optimisticId);
      }
      rethrow;
    }

    final mid = Map<String, dynamic>.from(inserted as Map)['id'].toString();
    if (kDebugMode) {
      debugPrint(
          '[DM] sent message=${maskDebugId(mid)} files=${fileIds?.length ?? 0}');
    }

    if (hasFiles) {
      await _sb
          .from('chat_files')
          .update({'message_id': mid})
          .inFilter('id', fileIds)
          .eq('chat_id', chatId);
    }

    await _publishMessageById(chatId: chatId, messageId: mid);
    return mid;
  }

  // 5) Прочитано до сообщения
  static Future<void> markRead(
      {required String chatId, required String messageId}) async {
    final uid = _sb.auth.currentUser?.id;
    if (uid == null) return;
    await _sb.from('chat_reads').upsert({
      'chat_id': chatId,
      'user_id': uid,
      'last_message_id': messageId,
      'seen_at': DateTime.now().toIso8601String(),
    }, onConflict: 'chat_id,user_id');
  }

  /// Peer read cursor for DM receipts (`peer.last_read_at >= message.created_at`).
  static Future<DateTime?> getPeerLastReadAt({
    required String chatId,
    required String peerId,
  }) async {
    if (chatId.isEmpty || peerId.isEmpty) return null;
    final row = await _sb
        .from('chat_reads')
        .select('last_read_at')
        .eq('chat_id', chatId)
        .eq('user_id', peerId)
        .maybeSingle();
    final raw = row?['last_read_at'];
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
  }

  // 6) Метаданные непрочитанного
  static Future<Map<String, dynamic>> getUnreadMeta(String chatId) async {
    final res =
        await _sb.rpc('get_unread_in_chat', params: {'p_chat_id': chatId});
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

  /// Edit own plain-text message via SECURITY DEFINER RPC.
  /// Returns the updated message and publishes it into the local stream.
  static Future<Message> editOwnMessage({
    required String messageId,
    required String text,
  }) async {
    final res = await _sb.rpc('edit_own_message', params: {
      'p_message_id': messageId,
      'p_text': text,
    });

    Map<String, dynamic>? row;
    if (res is Map) {
      row = Map<String, dynamic>.from(res);
    } else if (res is List && res.isNotEmpty) {
      row = Map<String, dynamic>.from(res.first as Map);
    }
    if (row == null) {
      throw Exception('empty_edit_response');
    }

    final chatId = (row['chat_id'] ?? '').toString();
    await _hydrateAuthor(row);
    final files = chatId.isEmpty
        ? <String, List<ChatFile>>{}
        : await _loadFilesByMessage([messageId]);
    final message = _messageFromRow(row, chatId: chatId).copyWith(
      attachments: files[messageId] ?? const [],
    );

    if (chatId.isNotEmpty) {
      final merged = ChatMessageMemoryCache.reconcileUpsert(chatId, message);
      final current = _streamMessages[chatId];
      if (current != null) {
        current
          ..clear()
          ..addAll(merged);
      }
      final ctrl = _streamControllers[chatId];
      if (ctrl != null && !ctrl.isClosed) {
        ctrl.add(List<Message>.unmodifiable(merged));
      }
    }

    return message;
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
      final row = await _sb
          .from('chat_files')
          .select('*')
          .eq('id', fileId)
          .maybeSingle();
      if (row == null) return null;
      return ChatFile.fromJson(Map<String, dynamic>.from(row as Map));
    } catch (_) {
      return null;
    }
  }
}
