// FILE: lib/src/ui/chats/data/dm_api.dart
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_memory_cache.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';
import 'blocks_api.dart';
import 'chat_sync_realtime_gate.dart';

class ChatSyncResult {
  const ChatSyncResult._({
    required this.ok,
    this.messages = const <Message>[],
    this.hasMoreBefore = false,
    this.error,
  });

  final bool ok;
  final List<Message> messages;
  final bool hasMoreBefore;
  final Object? error;

  factory ChatSyncResult.success(
    List<Message> messages, {
    bool hasMoreBefore = false,
  }) =>
      ChatSyncResult._(
        ok: true,
        messages: messages,
        hasMoreBefore: hasMoreBefore,
      );

  factory ChatSyncResult.failure(Object error) =>
      ChatSyncResult._(ok: false, error: error);
}

class DmApi {
  static final SupabaseClient _sb = Supabase.instance.client;
  static final Map<String, List<Message>> _streamMessages = {};
  static final Map<String, StreamController<List<Message>>> _streamControllers =
      {};
  static final Map<String, StreamController<ChatMessagesViewState>>
      _viewControllers = {};
  static final Map<String, ChatMessagesViewState> _viewStates = {};
  static final Map<String, Future<ChatSyncResult>> _syncInFlight = {};
  static final Map<String, RealtimeChannel> _channels = {};
  static final Map<String, ChatSyncRealtimeGate> _syncGates = {};

  /// Per-chat clear boundary for the current user (one settings fetch).
  static final Map<String, DateTime?> _clearedAtByChat = {};

  /// Test counters: number of initial/page message fetches per chat.
  static final Map<String, int> debugLoadMessagesCounts = {};

  /// Test hook: replace page fetch inside [syncLatest] (delayed pages, etc.).
  static Future<({List<Message> messages, bool hasMore})> Function({
    required String chatId,
    required int limit,
    DateTime? clearedAt,
  })? debugSyncPageLoader;

  /// Test hook: replace targeted single-message load used by Realtime flush.
  static Future<Message?> Function({
    required String chatId,
    required String messageId,
  })? debugLoadMessageById;

  static void debugResetLoadCounts() => debugLoadMessagesCounts.clear();

  static int debugLoadCount(String chatId) =>
      debugLoadMessagesCounts[chatId] ?? 0;

  static ChatSyncRealtimeGate _gateFor(String chatId) {
    return _syncGates.putIfAbsent(
      chatId,
      () => ChatSyncRealtimeGate(
        applyUpsert: (messageId) => _applyRealtimeUpsert(chatId, messageId),
        applyDelete: (messageId) => _applyRealtimeDelete(chatId, messageId),
      ),
    );
  }

  /// Test helper: enqueue/apply an upsert through the same gate as Realtime.
  static Future<void> debugHandleRealtimeUpsert({
    required String chatId,
    required String messageId,
  }) =>
      _gateFor(chatId).handleUpsert(messageId);

  /// Test helper: enqueue/apply a delete through the same gate as Realtime.
  static Future<void> debugHandleRealtimeDelete({
    required String chatId,
    required String messageId,
  }) =>
      _gateFor(chatId).handleDelete(messageId);

  static ChatSyncRealtimeGate? debugGateFor(String chatId) =>
      _syncGates[chatId];

  static Future<void> _applyRealtimeUpsert(
    String chatId,
    String messageId,
  ) async {
    final clearedAt = await loadClearedAt(chatId);
    final message = debugLoadMessageById != null
        ? await debugLoadMessageById!(chatId: chatId, messageId: messageId)
        : await loadMessageById(chatId: chatId, messageId: messageId);
    if (message == null) return;
    if (clearedAt != null && !message.at.isAfter(clearedAt)) return;
    final snap = await ChatMessageCacheStore.reconcileUpsert(chatId, message);
    await ChatMessageCacheStore.pruneAtOrBefore(chatId, clearedAt);
    _emitView(
      chatId,
      ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: ChatMessageCacheStore.messagesSync(chatId),
        hasSnapshot: true,
        hasMoreBefore: snap.hasMoreBefore,
      ),
    );
  }

  static Future<void> _applyRealtimeDelete(
    String chatId,
    String messageId,
  ) async {
    final snap = await ChatMessageCacheStore.remove(chatId, messageId);
    _emitView(
      chatId,
      ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: snap.found ? snap.messages : const <Message>[],
        hasSnapshot: snap.found || ChatMessageCacheStore.hasSnapshot(chatId),
        hasMoreBefore: snap.hasMoreBefore,
      ),
    );
  }

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

  /// Test hook: seed clearedAt cache so sync can run without Supabase.
  static void debugPrimeClearedAt(String chatId, DateTime? value) {
    _clearedAtByChat[chatId] = value;
  }

  static ChatMessagesViewState viewStateFor(String chatId) {
    return _viewStates[chatId] ??
        ChatMessagesViewState(
          phase: ChatMessageCacheStore.hasSnapshot(chatId)
              ? ChatMessagesLoadPhase.ready
              : ChatMessagesLoadPhase.noSnapshot,
          messages: ChatMessageCacheStore.messagesSync(chatId),
          hasSnapshot: ChatMessageCacheStore.hasSnapshot(chatId),
          hasMoreBefore: ChatMessageCacheStore.peek(chatId).hasMoreBefore,
        );
  }

  static void _emitView(String chatId, ChatMessagesViewState state) {
    _viewStates[chatId] = state;
    final list = List<Message>.unmodifiable(state.messages);
    final current = _streamMessages.putIfAbsent(chatId, () => <Message>[]);
    current
      ..clear()
      ..addAll(list);
    final listCtrl = _streamControllers[chatId];
    if (listCtrl != null && !listCtrl.isClosed) {
      listCtrl.add(list);
    }
    final viewCtrl = _viewControllers[chatId];
    if (viewCtrl != null && !viewCtrl.isClosed) {
      viewCtrl.add(state);
    }
  }

  // 2) Загрузить сообщения (bulk RPC; no per-message profile N+1)
  static Future<List<Message>> loadMessages({
    required String chatId,
    int limit = 50,
    DateTime? since,
    DateTime? clearedAt,
  }) async {
    final page = await loadMessagesPage(
      chatId: chatId,
      limit: limit,
      clearedAt: clearedAt,
    );
    return page.messages;
  }

  static Future<({List<Message> messages, bool hasMore})> loadMessagesPage({
    required String chatId,
    int limit = 50,
    DateTime? beforeAt,
    String? beforeId,
    DateTime? clearedAt,
  }) async {
    debugLoadMessagesCounts[chatId] =
        (debugLoadMessagesCounts[chatId] ?? 0) + 1;

    final clearFloor = clearedAt ?? await loadClearedAt(chatId);
    await ChatMessageCacheStore.pruneAtOrBefore(chatId, clearFloor);

    try {
      final rows = await _sb.rpc('get_chat_messages_page', params: {
        'p_chat_id': chatId,
        'p_limit': limit.clamp(1, 100),
        if (beforeAt != null) 'p_before_at': beforeAt.toUtc().toIso8601String(),
        if (beforeId != null && beforeId.isNotEmpty) 'p_before_id': beforeId,
      });

      final list = <Message>[];
      var hasMore = false;
      for (final row in (rows as List? ?? const [])) {
        final data = Map<String, dynamic>.from(row as Map);
        hasMore = data['has_more'] == true || hasMore;
        final message = _messageFromRow(data, chatId: chatId);
        if (clearFloor != null && !message.at.isAfter(clearFloor)) continue;
        list.add(message);
      }
      list.sort((a, b) {
        final byTime = a.at.compareTo(b.at);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
      if (kDebugMode) {
        debugPrint(
          '[DM] loadMessagesPage rpc chat=${maskDebugId(chatId)} '
          'rows=${list.length} hasMore=$hasMore',
        );
      }
      return (messages: list, hasMore: hasMore);
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[DM] get_chat_messages_page fallback chat=${maskDebugId(chatId)}: $e',
        );
      }
      return _loadMessagesLegacyPage(
        chatId: chatId,
        limit: limit,
        beforeAt: beforeAt,
        beforeId: beforeId,
        clearedAt: clearFloor,
      );
    }
  }

  /// Legacy table select used only when RPC is unavailable. Authors are left
  /// as provided by the row (no per-message get_user_profile loop).
  static Future<({List<Message> messages, bool hasMore})>
      _loadMessagesLegacyPage({
    required String chatId,
    int limit = 50,
    DateTime? beforeAt,
    String? beforeId,
    DateTime? clearedAt,
  }) async {
    var query = _sb.from('messages').select('*').eq('chat_id', chatId);

    if (clearedAt != null) {
      query = query.gt('created_at', clearedAt.toUtc().toIso8601String());
    }
    if (beforeAt != null) {
      query = query.lte('created_at', beforeAt.toUtc().toIso8601String());
    }

    final rows =
        await query.order('created_at', ascending: false).limit(limit + 1);

    final msgs = <Message>[];
    for (final row in (rows as List)) {
      final data = Map<String, dynamic>.from(row as Map);
      final id = (data['id'] ?? '').toString();
      if (beforeId != null && id == beforeId) continue;
      final message = _messageFromRow(data, chatId: chatId);
      if (clearedAt != null && !message.at.isAfter(clearedAt)) continue;
      msgs.add(message);
    }

    final hasMore = msgs.length > limit;
    final page = msgs.take(limit).toList().reversed.toList();

    final ids = page.map((m) => m.id).toList();
    if (ids.isNotEmpty) {
      final byMsg = await _loadFilesByMessage(ids);
      for (var i = 0; i < page.length; i++) {
        final m = page[i];
        page[i] = m.copyWith(attachments: byMsg[m.id] ?? const []);
      }
    }

    return (messages: page, hasMore: hasMore);
  }

  static Message _messageFromRow(Map<String, dynamic> m,
      {required String chatId}) {
    final authorName = (m['author_name'] ?? '').toString().trim();
    final authorLogin = (m['author_login'] ?? '').toString().trim();
    final attachments = _parseAttachments(m['attachments']);
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
      attachments: attachments,
      reactions: (m['reactions'] is Map)
          ? Map<String, int>.from(m['reactions'])
          : null,
      userReactions: m['user_reactions'] is List
          ? (m['user_reactions'] as List)
              .map((e) => e.toString())
              .where((s) => s.isNotEmpty)
              .toList()
          : null,
      isPinned: m['is_pinned'] == true,
    );
  }

  static List<ChatFile>? _parseAttachments(dynamic raw) {
    if (raw == null) return null;
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((item) => ChatFile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    }
    return null;
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

  /// Targeted single-message hydrate for Realtime / edit paths (one RPC ok).
  static Future<void> _hydrateAuthor(Map<String, dynamic> data) async {
    final authorId = (data['author_id'] ?? '').toString();
    if (authorId.isEmpty) return;
    if ((data['author_name'] ?? '').toString().trim().isNotEmpty &&
        (data['author_avatar_url'] ?? '').toString().trim().isNotEmpty) {
      return;
    }

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
      // Prefer bulk RPC page filtered by fetching single row via table + one hydrate.
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

  /// Older page load. Throws on network/RPC failure so UI does not treat
  /// errors as "end of history".
  static Future<({List<Message> messages, bool hasMore})> loadOlderMessages({
    required String chatId,
    required Message before,
    int limit = 50,
  }) async {
    final clearedAt = await loadClearedAt(chatId);
    final page = await loadMessagesPage(
      chatId: chatId,
      limit: limit,
      beforeAt: before.at,
      beforeId: before.id,
      clearedAt: clearedAt,
    );

    final older = page.messages.where((m) => m.id != before.id).toList()
      ..sort((a, b) => a.at.compareTo(b.at));

    await ChatMessageCacheStore.merge(
      chatId: chatId,
      messages: older,
      clearedAt: clearedAt,
      hasMoreBefore: page.hasMore,
    );
    await ChatMessageCacheStore.pruneAtOrBefore(chatId, clearedAt);

    final current = _streamMessages[chatId];
    final ctrl = _streamControllers[chatId];
    if (current != null && ctrl != null) {
      final existingIds = current.map((m) => m.id).toSet();
      final unique = older.where((m) => existingIds.add(m.id)).toList();
      if (unique.isNotEmpty) {
        current.insertAll(0, unique);
        final visible = ChatMessageCacheStore.messagesSync(chatId);
        current
          ..clear()
          ..addAll(visible);
        _emitView(
          chatId,
          viewStateFor(chatId).copyWith(
            phase: ChatMessagesLoadPhase.ready,
            messages: visible,
            hasSnapshot: true,
            hasMoreBefore: page.hasMore,
            clearError: true,
          ),
        );
        return (messages: unique, hasMore: page.hasMore);
      }
      _emitView(
        chatId,
        viewStateFor(chatId).copyWith(hasMoreBefore: page.hasMore),
      );
      return (messages: unique, hasMore: page.hasMore);
    }
    return (messages: older, hasMore: page.hasMore);
  }

  static Future<void> _publishMessageById({
    required String chatId,
    required String messageId,
    String? clientId,
  }) async {
    if (messageId.isEmpty) return;

    final message = await loadMessageById(chatId: chatId, messageId: messageId);
    if (message == null) return;

    final snap = await ChatMessageCacheStore.reconcileUpsert(
      chatId,
      message,
      clientId: clientId,
    );
    _emitView(
      chatId,
      ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: snap.messages,
        hasSnapshot: true,
        hasMoreBefore: snap.hasMoreBefore,
      ),
    );
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
    ChatMessageMemoryCache.upsert(chatId, local);
    final merged = ChatMessageCacheStore.messagesSync(chatId);
    _emitView(
      chatId,
      ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: merged,
        hasSnapshot: true,
        hasMoreBefore: ChatMessageCacheStore.peek(chatId).hasMoreBefore,
      ),
    );
    return clientId;
  }

  static void _markOptimisticFailed({
    required String chatId,
    required String clientId,
  }) {
    final current = ChatMessageCacheStore.messagesSync(chatId);
    if (current.isEmpty) return;
    final next = current.map((message) {
      if (message.clientId == clientId || message.id == clientId) {
        return message.copyWith(deliveryStatus: MessageDeliveryStatus.failed);
      }
      return message;
    }).toList();
    ChatMessageMemoryCache.replace(chatId, next);
    final merged = ChatMessageCacheStore.messagesSync(chatId);
    _emitView(
      chatId,
      ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: merged,
        hasSnapshot: true,
        hasMoreBefore: ChatMessageCacheStore.peek(chatId).hasMoreBefore,
      ),
    );
  }

  /// Single-flight latest sync. On error does NOT write [] over existing cache.
  static Future<ChatSyncResult> syncLatest({
    required String chatId,
    int limit = 50,
    bool invalidateClearBoundary = true,
  }) {
    if (chatId.isEmpty) {
      return Future.value(ChatSyncResult.success(const <Message>[]));
    }
    final existing = _syncInFlight[chatId];
    if (existing != null) return existing;

    final future = _syncLatestImpl(
      chatId: chatId,
      limit: limit,
      invalidateClearBoundary: invalidateClearBoundary,
    );
    _syncInFlight[chatId] = future;
    future.whenComplete(() {
      if (identical(_syncInFlight[chatId], future)) {
        _syncInFlight.remove(chatId);
      }
    });
    return future;
  }

  static Future<ChatSyncResult> _syncLatestImpl({
    required String chatId,
    required int limit,
    required bool invalidateClearBoundary,
  }) async {
    final gate = _gateFor(chatId);
    return gate.runExclusiveSync(() async {
      try {
        if (invalidateClearBoundary) invalidateClearedAt(chatId);
        final clearedAt = await loadClearedAt(chatId);
        final page = debugSyncPageLoader != null
            ? await debugSyncPageLoader!(
                chatId: chatId,
                limit: limit,
                clearedAt: clearedAt,
              )
            : await loadMessagesPage(
                chatId: chatId,
                limit: limit,
                clearedAt: clearedAt,
              );
        // DELETE tombstones win over a page fetched before the delete.
        final tombs = gate.pendingDeleteTombstones;
        final serverPage = tombs.isEmpty
            ? page.messages
            : page.messages
                .where((m) => !tombs.contains(m.id))
                .toList(growable: false);
        final snap = await ChatMessageCacheStore.applyLatestServerPage(
          chatId: chatId,
          serverPage: serverPage,
          pageLimit: limit,
          clearedAt: clearedAt,
          hasMoreBefore: page.hasMore,
        );
        _emitView(
          chatId,
          ChatMessagesViewState(
            phase: ChatMessagesLoadPhase.ready,
            messages: snap.messages,
            hasSnapshot: true,
            hasMoreBefore: snap.hasMoreBefore,
          ),
        );
        return ChatSyncResult.success(
          snap.messages,
          hasMoreBefore: snap.hasMoreBefore,
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[DM] syncLatest failed chat=${maskDebugId(chatId)}: $e');
        }
        final cached = ChatMessageCacheStore.peek(chatId);
        _emitView(
          chatId,
          ChatMessagesViewState(
            phase: ChatMessagesLoadPhase.error,
            messages: cached.found ? cached.messages : const <Message>[],
            hasSnapshot: cached.found,
            hasMoreBefore: cached.hasMoreBefore,
            error: e,
          ),
        );
        return ChatSyncResult.failure(e);
      }
      // Buffered Realtime ops flush in runExclusiveSync finally — even on error.
    });
  }

  /// Backward-compatible refresh. Never pretends a network error is an empty chat.
  static Future<List<Message>> refreshStream({required String chatId}) async {
    if (chatId.isEmpty) return const <Message>[];
    final result = await syncLatest(chatId: chatId);
    if (!result.ok) {
      return ChatMessageCacheStore.messagesSync(chatId);
    }
    return List<Message>.unmodifiable(result.messages);
  }

  static Future<void> _ensureSynced(String chatId) async {
    final current = _viewStates[chatId];
    if (current == null ||
        current.phase == ChatMessagesLoadPhase.noSnapshot ||
        current.phase == ChatMessagesLoadPhase.ready ||
        current.phase == ChatMessagesLoadPhase.error) {
      if (current != null && current.hasSnapshot) {
        _emitView(
          chatId,
          current.copyWith(phase: ChatMessagesLoadPhase.refreshing),
        );
      }
      await syncLatest(chatId: chatId);
    }
  }

  /// Rich state stream: snapshot-first, one sync, realtime patches.
  static Stream<ChatMessagesViewState> watchMessagesState({
    required String chatId,
  }) {
    if (_viewControllers.containsKey(chatId)) {
      final ctrl = _viewControllers[chatId]!;
      unawaited(_ensureSynced(chatId));
      return Stream<ChatMessagesViewState>.multi((controller) {
        final current = _viewStates[chatId];
        if (current != null) {
          controller.add(current);
        }
        final sub = ctrl.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      });
    }

    final viewCtrl = StreamController<ChatMessagesViewState>.broadcast();
    final listCtrl = StreamController<List<Message>>.broadcast();
    _viewControllers[chatId] = viewCtrl;
    _streamControllers[chatId] = listCtrl;
    _streamMessages.putIfAbsent(chatId, () => <Message>[]);

    unawaited(_bootstrapWatch(chatId));

    return viewCtrl.stream;
  }

  static Future<void> _bootstrapWatch(String chatId) async {
    // 1) Snapshot first (empty found snapshot is valid).
    final snap = await ChatMessageCacheStore.read(chatId);
    if (snap.found) {
      _emitView(
        chatId,
        ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.refreshing,
          messages: snap.messages,
          hasSnapshot: true,
          hasMoreBefore: snap.hasMoreBefore,
        ),
      );
    } else {
      _emitView(
        chatId,
        const ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.noSnapshot,
          messages: <Message>[],
          hasSnapshot: false,
        ),
      );
    }

    // 2) One realtime subscription.
    _ensureRealtime(chatId);

    // 3) Exactly one background sync (deduped).
    await syncLatest(chatId: chatId);
  }

  static void _ensureRealtime(String chatId) {
    if (_channels.containsKey(chatId)) return;

    String idFromPayload(PostgresChangePayload payload, {bool old = false}) {
      final record = old ? payload.oldRecord : payload.newRecord;
      return (record['id'] ?? '').toString();
    }

    Future<void> insertOne(PostgresChangePayload payload) async {
      final id = idFromPayload(payload);
      if (id.isEmpty) return;
      // Dedupe only when applying immediately; during sync/flush always buffer.
      final gate = _gateFor(chatId);
      if (!gate.isBusy) {
        final current = _streamMessages[chatId] ?? const <Message>[];
        if (current.any((m) => m.id == id)) return;
      }
      await gate.handleUpsert(id);
    }

    Future<void> updateOne(PostgresChangePayload payload) async {
      final id = idFromPayload(payload);
      if (id.isEmpty) return;
      await _gateFor(chatId).handleUpsert(id);
    }

    Future<void> deleteOne(PostgresChangePayload payload) async {
      final id = idFromPayload(payload, old: true);
      if (id.isEmpty) return;
      await _gateFor(chatId).handleDelete(id);
    }

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
        callback: (payload) => deleteOne(payload),
      )
      ..subscribe();

    _channels[chatId] = ch;

    final listCtrl = _streamControllers[chatId];
    listCtrl?.onCancel = () async {
      // Keep channel alive while view controller has listeners; tear down on logout.
    };
  }

  // 3) Realtime подписка по chat_id (list stream)
  static Stream<List<Message>> watchMessages({required String chatId}) {
    return watchMessagesState(chatId: chatId).map((s) => s.messages);
  }

  /// Stop realtime, clear in-memory streams/maps, clear clearedAt cache.
  static Future<void> clearSessionState() async {
    for (final ch in _channels.values) {
      try {
        await ch.unsubscribe();
      } catch (_) {}
    }
    _channels.clear();

    for (final ctrl in _streamControllers.values) {
      try {
        await ctrl.close();
      } catch (_) {}
    }
    _streamControllers.clear();

    for (final ctrl in _viewControllers.values) {
      try {
        await ctrl.close();
      } catch (_) {}
    }
    _viewControllers.clear();

    _streamMessages.clear();
    _viewStates.clear();
    _syncInFlight.clear();
    _syncGates.clear();
    _clearedAtByChat.clear();
    debugLoadMessagesCounts.clear();
    debugSyncPageLoader = null;
    debugLoadMessageById = null;
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
    // Always show the outgoing bubble immediately (Telegram-style).
    final optimisticId = _publishOptimisticMessage(
      chatId: chatId,
      userId: uid,
      text: text,
      replyToId: replyToId,
    );

    try {
      final res = await _sb.rpc('send_message_in_chat_with_files', params: {
        'p_chat_id': chatId,
        'p_text': text,
        'p_reply_to': replyToId,
        'p_file_ids': hasFiles ? fileIds : <String>[],
      });
      if (res is Map && res['id'] != null) {
        final id = res['id'].toString();
        await _publishMessageById(
          chatId: chatId,
          messageId: id,
          clientId: optimisticId,
        );
        return id;
      }
      if (res is String && res.isNotEmpty) {
        await _publishMessageById(
          chatId: chatId,
          messageId: res,
          clientId: optimisticId,
        );
        return res;
      }
      if (res is List && res.isNotEmpty) {
        final m = Map<String, dynamic>.from(res.first as Map);
        if (m['id'] != null) {
          final id = m['id'].toString();
          await _publishMessageById(
            chatId: chatId,
            messageId: id,
            clientId: optimisticId,
          );
          return id;
        }
      }
    } catch (e) {
      if (BlocksApi.isDmBlockedError(e)) {
        _markOptimisticFailed(chatId: chatId, clientId: optimisticId);
        rethrow;
      }
      // fallback below
    }

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
      _markOptimisticFailed(chatId: chatId, clientId: optimisticId);
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

    await _publishMessageById(
      chatId: chatId,
      messageId: mid,
      clientId: optimisticId,
    );
    return mid;
  }

  /// Drop a failed local bubble and resend (optimistic again).
  static Future<String> retryFailedText({
    required String chatId,
    required Message message,
  }) async {
    if (!message.isFailed) return '';
    final text = message.text.trim();
    final replyToId = message.replyToId;
    final fileIds = (message.attachments ?? const <ChatFile>[])
        .map((f) => f.id)
        .where((id) => id.isNotEmpty)
        .toList();
    if (text.isEmpty && fileIds.isEmpty) return '';

    final clientKey = message.clientId ?? message.id;
    await ChatMessageCacheStore.remove(chatId, message.id);
    if (clientKey.isNotEmpty && clientKey != message.id) {
      await ChatMessageCacheStore.remove(chatId, clientKey);
    }
    final merged = ChatMessageCacheStore.messagesSync(chatId);
    _emitView(
      chatId,
      ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: merged,
        hasSnapshot: true,
        hasMoreBefore: ChatMessageCacheStore.peek(chatId).hasMoreBefore,
      ),
    );
    return sendText(
      chatId: chatId,
      text: text,
      replyToId: replyToId,
      fileIds: fileIds.isEmpty ? null : fileIds,
    );
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

  // 8) Пин/удаление (SECURITY DEFINER RPC — оба участника ЛС могут откреплять)
  static Future<void> pinMessage(
    String messageId,
    bool pin, {
    String? chatId,
  }) async {
    final cid = (chatId ?? '').trim();
    List<Message>? previous;
    if (cid.isNotEmpty) {
      previous = ChatMessageCacheStore.messagesSync(cid);
      final next = previous
          .map((m) => m.id == messageId ? m.copyWith(isPinned: pin) : m)
          .toList();
      ChatMessageMemoryCache.replace(cid, next);
      _emitView(
        cid,
        ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.ready,
          messages: ChatMessageCacheStore.messagesSync(cid),
          hasSnapshot: true,
          hasMoreBefore: ChatMessageCacheStore.peek(cid).hasMoreBefore,
        ),
      );
    }

    try {
      await _sb.rpc('pin_message', params: {
        'p_message_id': messageId,
        'p_pinned': pin,
      });
    } catch (_) {
      if (cid.isNotEmpty && previous != null) {
        ChatMessageMemoryCache.replace(cid, previous);
        _emitView(
          cid,
          ChatMessagesViewState(
            phase: ChatMessagesLoadPhase.ready,
            messages: ChatMessageCacheStore.messagesSync(cid),
            hasSnapshot: true,
            hasMoreBefore: ChatMessageCacheStore.peek(cid).hasMoreBefore,
          ),
        );
      }
      rethrow;
    }
  }

  static Future<void> deleteMessage(String messageId) async {
    await _sb.from('messages').delete().eq('id', messageId);
  }

  /// Edit own plain-text message via SECURITY DEFINER RPC.
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
      final snap = await ChatMessageCacheStore.reconcileUpsert(chatId, message);
      _emitView(
        chatId,
        ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.ready,
          messages: snap.messages,
          hasSnapshot: true,
          hasMoreBefore: snap.hasMoreBefore,
        ),
      );
    }

    return message;
  }

  // 9) Upload
  static Future<String> upload(LocalAttach local, String chatId) async {
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
