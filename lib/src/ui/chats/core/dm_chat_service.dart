// FILE: lib/src/ui/chats/core/dm_chat_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import '../data/dm_api.dart';
import '../data/blocks_api.dart';
import 'i_chat_service.dart';

class CapabilityDenied implements Exception {
  const CapabilityDenied();
}

class OperationInvalidated implements Exception {
  const OperationInvalidated();
}

class CachedChatUnavailable implements Exception {
  const CachedChatUnavailable();
}

class DmChatService implements IChatService {
  final String peerId;
  String? _chatId;
  StreamSubscription<ChatMessagesViewState>? _sub;
  final _viewController = StreamController<ChatMessagesViewState>.broadcast();
  ChatMessagesViewState _viewState = ChatMessagesViewState.initial;
  bool _disposed = false;
  bool _watchStarted = false;
  final SessionCapabilities? _capabilities;
  final CapabilityPermit? _cachedReadPermit;
  final Future<ChatCacheSnapshot> Function(String, String)? _cacheReader;
  int _watchRevision = 0;

  DmChatService({required this.peerId, String? initialChatId})
      : _capabilities = null,
        _cachedReadPermit = null,
        _cacheReader = null,
        _chatId = (initialChatId == null || initialChatId.trim().isEmpty)
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

  /// Local adapter for existing chat UI. UI and upload side effects must be
  /// guarded separately before a screen is allowed to use this adapter.
  factory DmChatService.cachedOnly(
      {required String peerId,
      required String initialChatId,
      required SessionCapabilities capabilities,
      Future<ChatCacheSnapshot> Function(String, String)? cacheReader}) {
    final permit = capabilities.capture(SessionCapability.cachedRead);
    if (permit == null ||
        capabilities.mode != SessionCapabilityMode.cacheOnly) {
      throw const CapabilityDenied();
    }
    if (initialChatId.trim().isEmpty) throw const CachedChatUnavailable();
    return DmChatService._cached(
        peerId, initialChatId.trim(), capabilities, permit, cacheReader);
  }

  DmChatService._cached(this.peerId, this._chatId, this._capabilities,
      this._cachedReadPermit, this._cacheReader) {
    _capabilities!.addListener(_onCapabilityChanged);
    // A project-bound reader must never paint the legacy uid-only memory cache.
    if (_cacheReader != null) return;
    try {
      final cached = ChatMessageCacheStore.peek(_chatId!,
          userId: _cachedReadPermit!.userId);
      if (cached.found) _setCachedSnapshot(cached);
    } catch (_) {
      _setView(const ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.error,
          messages: <Message>[],
          hasSnapshot: false,
          error: CachedChatUnavailable()));
    }
  }

  bool get _cacheOnly => _capabilities != null;
  /// Read-only UI boundaries must observe this exact permit, not just the
  /// current account or the fact that a cache exists.
  bool get isCachedOnly => _cacheOnly;
  bool get canReadCached => _cacheAllowed;
  Listenable? get cachedAccessChanges => _capabilities;
  bool get _cacheAllowed =>
      _cacheOnly &&
      !_disposed &&
      _capabilities!.mode == SessionCapabilityMode.cacheOnly &&
      _capabilities.permits(_cachedReadPermit!, SessionCapability.cachedRead);

  void _requireOnline() {
    if (_cacheOnly) {
      if (!_cacheAllowed) throw const OperationInvalidated();
      throw const CapabilityDenied();
    }
  }

  void _onCapabilityChanged() {
    if (!_cacheAllowed && !_disposed) {
      _watchRevision++;
      _setView(const ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.error,
          messages: <Message>[],
          hasSnapshot: false,
          error: OperationInvalidated()));
    }
  }

  void _setCachedSnapshot(ChatCacheSnapshot snapshot) {
    final boundary = snapshot.clearedAt;
    final messages = boundary == null
        ? snapshot.messages
        : snapshot.messages
            .where((message) => message.at.isAfter(boundary))
            .toList();
    _setView(ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: List<Message>.unmodifiable(messages),
        hasSnapshot: true));
  }

  @override
  ChatMode get mode => ChatMode.dm;

  @override
  bool get supportsAssignments => false;

  @override
  bool get supportsNotes => false;

  @override
  String get currentUserId => _cacheOnly
      ? (_cacheAllowed ? _cachedReadPermit!.userId : '')
      : Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  String? get chatId => _cacheOnly && !_cacheAllowed ? null : _chatId;

  @override
  ChatMessagesViewState get messagesViewState => _cacheOnly && !_cacheAllowed
      ? const ChatMessagesViewState(
          phase: ChatMessagesLoadPhase.error,
          messages: <Message>[],
          hasSnapshot: false,
          error: OperationInvalidated())
      : _viewState;

  @override
  Future<String> ensureChatId() async {
    if (_cacheOnly) {
      if (!_cacheAllowed) throw const OperationInvalidated();
      return _chatId!;
    }
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
    final stream = Stream<ChatMessagesViewState>.multi((controller) {
      controller.add(messagesViewState);
      final sub = _viewController.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
    return _cacheOnly
        ? stream.map((state) => _cacheAllowed ? state : messagesViewState)
        : stream;
  }

  Future<void> _startWatch() async {
    if (_cacheOnly) {
      final revision = ++_watchRevision;
      if (!_cacheAllowed) {
        _onCapabilityChanged();
        return;
      }
      ChatCacheSnapshot snapshot;
      try {
        snapshot =
            await (_cacheReader?.call(_chatId!, _cachedReadPermit!.userId) ??
                ChatMessageCacheStore.read(_chatId!,
                    userId: _cachedReadPermit!.userId));
      } catch (_) {
        snapshot = ChatCacheSnapshot.notFound;
      }
      if (_disposed || revision != _watchRevision || !_cacheAllowed) return;
      if (snapshot.found) {
        _setCachedSnapshot(snapshot);
      } else {
        _setView(const ChatMessagesViewState(
            phase: ChatMessagesLoadPhase.error,
            messages: <Message>[],
            hasSnapshot: false,
            error: CachedChatUnavailable()));
      }
      return;
    }
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
  List<Message> get currentMessages => messagesViewState.messages;

  @override
  Future<List<Message>> loadOlderMessages(
      {required Message before, int limit = 50}) async {
    _requireOnline();
    final cid = await ensureChatId();
    final page = await DmApi.loadOlderMessages(
        chatId: cid, before: before, limit: limit);
    _setView(_viewState.copyWith(hasMoreBefore: page.hasMore));
    return page.messages;
  }

  @override
  Future<Map<String, dynamic>> getUnreadMeta() async {
    _requireOnline();
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
    _requireOnline();
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
    _requireOnline();
    final cid = await ensureChatId();
    return DmApi.sendText(
        chatId: cid, text: text, replyToId: replyToId, fileIds: fileIds);
  }

  Future<String> retryFailedText(Message message) async {
    _requireOnline();
    final cid = await ensureChatId();
    return DmApi.retryFailedText(chatId: cid, message: message);
  }

  @override
  Future<void> toggleReaction(String messageId, String emoji) {
    _requireOnline();
    return DmApi.toggleReaction(messageId, emoji);
  }

  @override
  Future<void> pinMessage(String messageId, bool pin) async {
    _requireOnline();
    final cid = await ensureChatId();
    await DmApi.pinMessage(messageId, pin, chatId: cid);
  }

  @override
  Future<void> deleteMessage(String messageId) {
    _requireOnline();
    return DmApi.deleteMessage(messageId);
  }

  @override
  Future<Message> editOwnMessage(String messageId, String text) {
    _requireOnline();
    return DmApi.editOwnMessage(messageId: messageId, text: text);
  }

  @override
  Future<String> upload(LocalAttach local) async {
    _requireOnline();
    final cid = await ensureChatId();
    return DmApi.upload(local, cid);
  }

  @override
  Future<ChatFile?> getFile(String fileId) {
    _requireOnline();
    return DmApi.getFile(fileId);
  }

  @override
  Future<void> retryLoadMessages() async {
    if (_cacheOnly) {
      if (!_cacheAllowed) throw const OperationInvalidated();
      await _startWatch();
      return;
    }
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
    _watchRevision++;
    _capabilities?.removeListener(_onCapabilityChanged);
    await _sub?.cancel();
    _sub = null;
    await _viewController.close();
  }
}
