// FILE: lib/src/ui/chats/core/dm_chat_service.dart
import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import '../data/dm_api.dart';
import '../data/blocks_api.dart';
import 'i_chat_service.dart';

class DmChatService implements IChatService {
  final String peerId;
  String? _chatId;
  StreamSubscription<ChatMessagesViewState>? _sub;
  final _viewController = StreamController<ChatMessagesViewState>.broadcast();
  ChatMessagesViewState _viewState = ChatMessagesViewState.initial;
  bool _disposed = false;
  bool _watchStarted = false;

  DmChatService({required this.peerId, String? initialChatId})
      : _chatId = (initialChatId == null || initialChatId.trim().isEmpty)
            ? null
            : initialChatId.trim() {
    final cid = _chatId;
    if (cid == null) return;
    final cached = ChatMessageCacheStore.peek(cid);
    if (cached.found) {
      _viewState = ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.refreshing,
        messages: cached.messages,
        hasSnapshot: true,
        hasMoreBefore: cached.hasMoreBefore,
      );
    }
  }

  @override
  ChatMode get mode => ChatMode.dm;

  @override
  bool get supportsAssignments => false;

  @override
  bool get supportsNotes => false;

  @override
  String get currentUserId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  String? get chatId => _chatId;

  @override
  ChatMessagesViewState get messagesViewState => _viewState;

  @override
  Future<String> ensureChatId() async {
    if (_chatId != null && _chatId!.isNotEmpty) return _chatId!;
    _chatId = await DmApi.getOrCreateChatId(peerId: peerId);
    return _chatId!;
  }

  void _setView(ChatMessagesViewState next) {
    _viewState = next;
    if (!_viewController.isClosed) {
      _viewController.add(next);
    }
  }

  @override
  Stream<ChatMessagesViewState> watchMessagesState() {
    if (!_watchStarted) {
      _watchStarted = true;
      unawaited(_startWatch());
    }
    return Stream<ChatMessagesViewState>.multi((controller) {
      controller.add(_viewState);
      final sub = _viewController.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  Future<void> _startWatch() async {
    String cid;
    try {
      cid = await ensureChatId();
    } catch (e) {
      if (BlocksApi.isDmBlockedError(e)) {
        _setView(const ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.ready,
          messages: <Message>[],
          hasSnapshot: true,
        ));
        return;
      }
      _setView(ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.error,
        messages: const <Message>[],
        hasSnapshot: false,
        error: e,
      ));
      return;
    }
    if (_disposed) return;

    // Paint persistent/memory data before any network-dependent clear-boundary
    // lookup. The server refresh below remains authoritative.
    final snap = await ChatMessageCacheStore.read(cid);
    if (_disposed) return;
    if (snap.found) {
      _setView(ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.refreshing,
        messages: snap.messages,
        hasSnapshot: true,
        hasMoreBefore: snap.hasMoreBefore,
      ));
    } else {
      _setView(const ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.noSnapshot,
        messages: <Message>[],
        hasSnapshot: false,
      ));
    }

    final clearedAt = await DmApi.loadClearedAt(cid);
    final pruned = await ChatMessageCacheStore.pruneAtOrBefore(cid, clearedAt);
    if (_disposed) return;
    if (pruned.found &&
        (pruned.messages.length != _viewState.messages.length ||
            pruned.clearedAt != snap.clearedAt)) {
      _setView(ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.refreshing,
        messages: pruned.messages,
        hasSnapshot: true,
        hasMoreBefore: pruned.hasMoreBefore,
      ));
    }

    await _sub?.cancel();
    _sub = DmApi.watchMessagesState(chatId: cid).listen(
      (state) {
        if (_disposed) return;
        _setView(state);
      },
      onError: (Object e) {
        if (_disposed) return;
        final cached = ChatMessageCacheStore.peek(cid);
        _setView(ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.error,
          messages: cached.found ? cached.messages : _viewState.messages,
          hasSnapshot: cached.found || _viewState.hasSnapshot,
          hasMoreBefore: cached.hasMoreBefore,
          error: e,
        ));
      },
    );
  }

  @override
  Stream<List<Message>> watchMessages() =>
      watchMessagesState().map((s) => s.messages);

  @override
  List<Message> get currentMessages => _viewState.messages;

  @override
  Future<List<Message>> loadOlderMessages(
      {required Message before, int limit = 50}) async {
    final cid = await ensureChatId();
    final page = await DmApi.loadOlderMessages(
        chatId: cid, before: before, limit: limit);
    _setView(_viewState.copyWith(hasMoreBefore: page.hasMore));
    return page.messages;
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

  Future<String> retryFailedText(Message message) async {
    final cid = await ensureChatId();
    return DmApi.retryFailedText(chatId: cid, message: message);
  }

  @override
  Future<void> toggleReaction(String messageId, String emoji) =>
      DmApi.toggleReaction(messageId, emoji);

  @override
  Future<void> pinMessage(String messageId, bool pin) async {
    final cid = await ensureChatId();
    await DmApi.pinMessage(messageId, pin, chatId: cid);
  }

  @override
  Future<void> deleteMessage(String messageId) =>
      DmApi.deleteMessage(messageId);

  @override
  Future<Message> editOwnMessage(String messageId, String text) =>
      DmApi.editOwnMessage(messageId: messageId, text: text);

  @override
  Future<String> upload(LocalAttach local) async {
    final cid = await ensureChatId();
    return DmApi.upload(local, cid);
  }

  @override
  Future<ChatFile?> getFile(String fileId) => DmApi.getFile(fileId);

  @override
  Future<void> retryLoadMessages() async {
    final cid = _chatId;
    if (cid == null || cid.isEmpty) {
      _watchStarted = false;
      await _startWatch();
      return;
    }
    _setView(_viewState.copyWith(
      phase: _viewState.hasSnapshot
          ? ChatMessagesLoadPhase.refreshing
          : ChatMessagesLoadPhase.noSnapshot,
      clearError: true,
    ));
    await DmApi.syncLatest(chatId: cid);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    await _viewController.close();
  }
}
