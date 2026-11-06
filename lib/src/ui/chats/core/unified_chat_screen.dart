import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';
import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:student_platform/src/core/qa_rotation_navigation_guard.dart';
import 'cached_chat_message_bubble.dart';
import 'cached_chat_composer.dart';
import 'scoped_forward_author_resolver.dart';
// FILE: lib/src/ui/chats/core/unified_chat_screen.dart
// ignore_for_file: unnecessary_import, unused_import, unused_field, unused_element, dead_null_aware_expression, invalid_null_aware_operator, deprecated_member_use

import 'dart:async';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart' as services;

import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';

import 'package:student_platform/src/ui/learning/tabs/chat/actions/chat_actions.dart'
    as ca;
import 'package:student_platform/src/ui/learning/tabs/chat/edit_message_dialog.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/widgets.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/inline_search_bar.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/selection_bars.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/photo_send_choice.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/create_topic_selection_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/collections/create_collection_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_composer_capabilities_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_composer_capabilities.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';

import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/services/push/active_chat_tracker.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/ui/learning/global_cache.dart';

import '../media/chat_media_sheet.dart';
import '../forward/forward_picker.dart';
import '../forward/forward_pick_nav.dart';
import 'forward_payload.dart';
import '../forward/forward_outbox.dart';
import '../forward/forward_send_gate.dart';
import '../forward/durable_forward_outbox.dart';
import '../forward/durable_forward_pending_notice.dart';
import '../forward/confirm_ready_forward.dart';
import '../forward/sent_forward_sentinel.dart';
import '../forward/forward_outbox_host.dart';
import '../data/dm_api.dart';
import '../data/blocks_api.dart';
import '../dm_title.dart';

import 'i_chat_service.dart';
import 'dm_chat_service.dart';
import 'chat_messages_load_state.dart';

// ⤵️ DM-композер (новый файл ниже)
import 'dm_composer_bar.dart';

class UnifiedChatScreen extends StatefulWidget {
  const UnifiedChatScreen({
    super.key,
    required this.service,
    this.title,
    this.hideAvatars = false,
    this.peerAvatarUrl,
    this.onOpenPeer,
    this.debugPickForwardTarget,
    this.debugCopyForwardFile,
    this.debugAfterDurableCancel,
    this.onlineBarrier,
    this.sessionIsCurrent,
    this.cachedAuthorResolver,
    this.debugCanComposeDm,
  });

  final IChatService service;
  @visibleForTesting
  final bool Function()? debugCanComposeDm;
  final String? title;
  final bool hideAvatars;

  // для ЛС
  final String? peerAvatarUrl;
  final VoidCallback? onOpenPeer;
  /// Optional guard for automatic work started by a scoped push route.
  final OnlineSideEffectBarrier? onlineBarrier;
  final bool Function()? sessionIsCurrent;
  final ScopedForwardAuthorResolver? cachedAuthorResolver;
  @visibleForTesting
  final Future<ForwardTarget?> Function(BuildContext, bool Function())? debugPickForwardTarget;
  @visibleForTesting
  final Future<ForwardFileRef> Function(ForwardFileRef source, String chat)? debugCopyForwardFile;
  @visibleForTesting
  final Future<void> Function()? debugAfterDurableCancel;

  @override
  State<UnifiedChatScreen> createState() => _UnifiedChatScreenState();
}

class _UnifiedChatScreenState extends State<UnifiedChatScreen> {
  bool get _autoWorkCurrent {
    final barrier = widget.onlineBarrier, guard = widget.sessionIsCurrent;
    if (barrier == null && guard == null) return true;
    try { return mounted && barrier != null && guard != null && barrier.isOpen && guard(); }
    catch (_) { return false; }
  }

  Future<void> _runAutoWork(Future<void> Function(bool Function()) operation) async {
    final barrier = widget.onlineBarrier, guard = widget.sessionIsCurrent;
    final service = widget.service;
    if (barrier == null && guard == null) {
      await operation(() => true);
      return;
    }
    bool current() {
      try {
        return mounted && barrier != null && guard != null && barrier.isOpen &&
            identical(widget.onlineBarrier, barrier) &&
            identical(widget.sessionIsCurrent, guard) &&
            identical(widget.service, service) && guard();
      } catch (_) { return false; }
    }
    if (barrier == null || !current()) return;
    await barrier.run(() async { if (current()) await operation(current); });
  }
  static const bool enableTypingIndicator = false;
  // The host keeps the experimental mode disabled until both consumers and
  // migration are reviewed together.
  bool get _durableForwards => ForwardOutboxHost.usesDurable(context);

  final _scroll = ScrollController();
  final _ctrl = TextEditingController();
  final _composerFocus = FocusNode();

  late final ChatScrollController _chatScroll;
  late final ChatSearchController _search;
  late final PinController _pinsCtl;
  late final ChatAttachmentsController _att;
  late final Stream<ChatMessagesViewState> _messagesStream;
  late final IChatService _screenService;
  late final bool _initialCachedOnly;

  late final FileService _fileService = FileService();
  final GlobalCache _globalCache = GlobalCache();

  final Map<String, GlobalKey> _messageKeys = {};
  final Map<String, GlobalKey> _bubbleBoundaryKeys = {};
  void _pruneMessageKeys(Set<String> aliveIds) =>
      _messageKeys.removeWhere((id, _) => !aliveIds.contains(id));
  String? _hoveredMessageId;

  bool _showJump = false;
  bool _loadingOlderMessages = false;
  bool _hasMoreOlderMessages = true;
  Message? _replyTo;
  Message? _editingMessage;

  final Set<String> _typingUsers = {};
  Timer? _myTypingOff;
  List<String> get _visibleTypingUsers =>
      _typingUsers.where((name) => name != 'Вы').toList();
  bool get _someoneTyping =>
      enableTypingIndicator && _visibleTypingUsers.isNotEmpty;

  // DM-only: track if typing hook is attached
  bool _typingHookAttached = false;
  bool get _isDm => widget.service.mode == ChatMode.dm;

  // ===== DM Draft state =====
  String? _currentChatIdDm;
  Timer? _draftSaveTimerDm;
  bool _dmTextHookAttached = false;
  static const services.MethodChannel _keyboardChannel =
      services.MethodChannel('keyboard_image_channel');

  String? _lastMarkedReadId;
  Timer? _seenDebounce;
  String? _lastRenderedLastId;

  DateTime? _entrySeenAt;
  bool _showEntryNewBadge = false;

  // DM-only: peer read cursor for delivery/read ticks
  DateTime? _peerLastReadAt;
  RealtimeChannel? _dmPeerReadsChannel;

  bool _selecting = false;
  final Set<String> _selectedIds = {};

  bool _forwardPackageAttached = false;
  bool _preparingForward = false;
  bool _forwardPreparationFailed = false;
  int _forwardPreparationGeneration = 0;
  final List<String> _forwardSelectedIds = [];
  final List<String> _stagedForwardFileIds = [];
  final Set<String> _requiredForwardFileIds = {};
  ForwardPayload? _stagedForward;
  DurableForwardOutbox? _durableOutbox;
  DurableForwardReceipt? _durableReceipt;
  bool _durableBlocked = true;
  (String, int, String, String)? _legacyTextScope;
  ForwardOutboxSession? _legacyTextOutbox;

  // Блокировка повторных отправок и индикатор фоновых загрузок
  bool _isSending = false;
  bool get _isUploadingAttachments => _preparingForward || _att.hasActiveUploads;
  bool get _hasFailedAttachments => _forwardPreparationFailed || _att.hasFailedUploads;

  // DM block relationship (one RPC on open; no realtime on user_blocks)
  bool _dmComposerReady = false;
  bool _chatInitializing = false;
  bool _chatInitializationFailed = false;
  bool _draftRestored = false;
  bool _dmBlockLoaded = false;
  bool _iBlockedPeer = false;
  bool _dmAvailable = true;
  bool _blockActionBusy = false;

  bool get _canComposeDm {
    var allowed = !_isDm ||
        (_dmComposerReady && _dmBlockLoaded && _dmAvailable && !_blockActionBusy);
    assert(() {
      allowed = widget.debugCanComposeDm?.call() ?? allowed;
      return true;
    }());
    return allowed;
  }

  Future<void> _pickPhotoForChat() async {
    if (!_canComposeDm) return;
    final owner = ChatFileAccess.userId;
    final epoch = ChatFileAccess.generation;
    final service = widget.service;
    bool current() => mounted && owner != null &&
        ChatFileAccess.userId == owner && ChatFileAccess.generation == epoch &&
        identical(widget.service, service) && _canComposeDm;
    final compress = await choosePhotoSendMode(context);
    if (compress == null || !current()) return;
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null || !current()) return;
    final size = await File(picked.path).length();
    if (!current()) return;
    final chatId = await service.ensureChatId();
    if (!current()) return;
    final file = LocalAttach(
      path: picked.path,
      name: picked.name,
      mimeType: _guessMime(picked.path),
      size: size,
      isImage: true,
      preserveOriginal: !compress,
    );
    if (_att.add(file)) {
      unawaited(_att.upload(file, teamId: null, chatId: chatId));
      if (_isDm) _saveDraftDmDebounced();
    }
  }

  Future<bool> _retryAfterSessionChange(LocalAttach file, {String? teamId}) async {
    if (!_att.sessionInterrupted) return false;
    final target = _att.ownedTargetForRetry(file);
    if (target != null) await _att.retry(file, teamId: teamId, chatId: target,
        canDispatch: () => mounted && _canComposeDm);
    if (mounted && _att.sessionInterrupted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Не удалось подтвердить сессию. Выбранный файл не удалён.')));
    }
    return true;
  }

  // якорь для «⋯»
  final GlobalKey _kebabKey = GlobalKey();

  late final _capsRepo = ChatComposerCapabilitiesRepository();
  ChatComposerCapabilities? _composerCaps;
  bool _capsLoading = true;

  @override
  void initState() {
    super.initState();
    _screenService = widget.service;
    _initialCachedOnly = _screenService is DmChatService &&
        _screenService.isCachedOnly;
    _messagesStream = widget.service.watchMessagesState();
    _chatScroll = ChatScrollController(_scroll, _messageKeys);
    _search = ChatSearchController();
    _pinsCtl = PinController();
    // Do not initialize network, presence, draft, file or keyboard handlers
    // for a local-only service. This path is an experimental QA boundary.
    if (_initialCachedOnly) return;
    _att = ChatAttachmentsController(
        _fileService, _globalCache, Supabase.instance.client,
        authScope: AuthSessionScopeHost.maybeRead(context),
        capabilities: SessionCapabilitiesHost.maybeRead(context),
        rotationReceipt: QaRotationNavigationGuard.maybeRead(context))
      ..addListener(() {
        if (!mounted) return;
        setState(() {});
        if (_isDm && !_att.sessionInterrupted) _saveDraftDmDebounced();
      });

    // ignore: discarded_futures
    _loadComposerCapabilities();
    _scroll.addListener(_onScroll);
    // Attach typing listener only for non-DM (group) chats
    if (!_isDm) {
      _ctrl.addListener(_onTyping);
      _typingHookAttached = true;
    } else {
      // DM: track text changes for draft saving only
      _ctrl.addListener(_onTextChangedDm);
      _dmTextHookAttached = true;
    }

    // Force-save draft on composer blur
    _composerFocus.addListener(() {
      if (!_composerFocus.hasFocus) _forceSaveDraftDm();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initializeChat());
    });

    // Optional: handle keyboard image paste like ChatTab
    _keyboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onKeyboardImagePicked' || call.method == 'onPicked') {
        final path = (call.arguments ?? '') as String;
        if (path.isNotEmpty && mounted) {
          if (!_canComposeDm) return null;
          final file = LocalAttach(
            path: path,
            name: path.split('/').last,
            mimeType: 'image/jpeg',
            size: await File(path).length(),
            isImage: true,
          );
          _att.add(file);
          final cid = await widget.service.ensureChatId();
          _att.upload(file, teamId: null, chatId: cid);
          _saveDraftDmDebounced();
        }
      }
      return null;
    });
  }

  Future<void> _initializeChat() async {
    if (_chatInitializing || !mounted) return;
    final outbox = ForwardOutbox.capture(context);
    setState(() {
      _chatInitializing = true;
      _chatInitializationFailed = false;
    });
    String cid;
    try {
      if (_isDm) await _loadDmBlockRelationship();
      if (!mounted) return;
      cid = await widget.service.ensureChatId();
      if (!mounted) return;
      _currentChatIdDm = cid;
      ActiveChatTracker.instance.enter(cid);
      if (!_draftRestored) {
        _restoreDraftDm();
        _draftRestored = true;
      }
      await _consumeForwardOutboxIfAny(cid, outbox, fromInitialization: true);
      if (!mounted) return;
      setState(() => _dmComposerReady = true);
    } catch (e) {
      if (!mounted) return;
      if (_isDm && BlocksApi.isDmBlockedError(e)) {
        setState(() {
          _dmAvailable = false;
          _dmBlockLoaded = true;
        });
        _showDmBlockedSnack();
      } else {
        setState(() => _chatInitializationFailed = true);
        debugPrint('[UnifiedChat] initialization failed: $e');
      }
      return;
    } finally {
      if (mounted) setState(() => _chatInitializing = false);
    }
    // History and receipt failures must not disable an initialized composer.
    try {
      await _initEntryBoundary();
      if (!mounted) return;
      if (_isDm) await _initDmPeerReadReceipts(cid);
      if (!mounted) return;
      unawaited(_prefetchOldFilesForDm());
      await _jumpToBottom();
      if (!mounted) return;
      final list = widget.service.currentMessages;
      if (list.isNotEmpty && _chatScroll.atBottom()) {
        unawaited(_markReadSafely(list.last.id));
      }
    } catch (e) {
      debugPrint('[UnifiedChat] optional initialization failed: $e');
    }
  }

  @override
  void dispose() {
    if (_initialCachedOnly) {
      _scroll.dispose();
      _ctrl.dispose();
      _composerFocus.dispose();
      super.dispose();
      return;
    }
    ActiveChatTracker.instance.leave(_currentChatIdDm);
    try {
      final list = widget.service.currentMessages;
      if (list.isNotEmpty && _autoWorkCurrent) _markReadSafely(list.last.id);
    } catch (_) {}
    _forceSaveDraftDm();
    _seenDebounce?.cancel();
    _unsubscribeDmPeerReadReceipts();
    _scroll.removeListener(_onScroll);
    if (_typingHookAttached) {
      _ctrl.removeListener(_onTyping);
    }
    if (_dmTextHookAttached) {
      _ctrl.removeListener(_onTextChangedDm);
    }
    unawaited(_keyboardChannel.invokeMethod('dispose').catchError((_) {}));
    _keyboardChannel.setMethodCallHandler(null);
    _scroll.dispose();
    _ctrl.dispose();
    _composerFocus.dispose();
    _myTypingOff?.cancel();
    if (const bool.fromEnvironment('CHAT_ATTACHMENT_SESSION_FENCE_QA')) _att.dispose();
    super.dispose();
  }

  String? get _dmPeerId {
    final s = widget.service;
    if (s is DmChatService) return s.peerId;
    return null;
  }

  Future<void> _loadDmBlockRelationship() async {
    final peerId = _dmPeerId;
    if (!_isDm || peerId == null || peerId.isEmpty) {
      if (mounted) {
        setState(() {
          _dmBlockLoaded = true;
          _dmAvailable = true;
          _iBlockedPeer = false;
        });
      }
      return;
    }
    try {
      final rel = await BlocksApi.getBlockRelationship(peerId);
      if (!mounted) return;
      setState(() {
        _iBlockedPeer = rel.iBlocked;
        _dmAvailable = rel.dmAvailable;
        _dmBlockLoaded = true;
      });
    } catch (e) {
      debugPrint('[UnifiedChat] get_block_relationship error: $e');
      if (!mounted) return;
      setState(() {
        // Fail-open for reading; send path still has server checks.
        _dmBlockLoaded = true;
        _dmAvailable = true;
        _iBlockedPeer = false;
      });
    }
  }

  void _showDmBlockedSnack() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Личные сообщения недоступны')),
    );
  }

  Future<void> _unblockPeerFromDm() async {
    final peerId = _dmPeerId;
    if (!_isDm ||
        peerId == null ||
        peerId.isEmpty ||
        _blockActionBusy ||
        _chatInitializing) return;
    setState(() => _blockActionBusy = true);
    try {
      await BlocksApi.unblockUser(peerId);
      if (!mounted) return;
      setState(() {
        _iBlockedPeer = false;
        _dmAvailable = true;
        _dmBlockLoaded = true;
      });
      if (!_dmComposerReady) await _initializeChat();
    } catch (e) {
      debugPrint('[UnifiedChat] unblock error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            BlocksApi.shortErrorMessage(e,
                fallback: 'Не удалось разблокировать'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _blockActionBusy = false);
    }
  }

  Future<void> _applyDmBlockedFromServer() async {
    await _loadDmBlockRelationship();
    if (!mounted) return;
    if (!_dmAvailable) {
      _att.clear();
      _ctrl.clear();
      setState(() => _replyTo = null);
      _showDmBlockedSnack();
    }
  }

  Future<void> _initDmPeerReadReceipts(String chatId) async {
    final peerId = _dmPeerId;
    if (!_isDm || chatId.isEmpty || peerId == null || peerId.isEmpty) return;

    try {
      final at = await DmApi.getPeerLastReadAt(chatId: chatId, peerId: peerId);
      if (mounted) setState(() => _peerLastReadAt = at);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[UnifiedChat] peer last_read_at load error: $e');
      }
    }

    _subscribeDmPeerReadReceipts(chatId: chatId, peerId: peerId);
  }

  void _subscribeDmPeerReadReceipts({
    required String chatId,
    required String peerId,
  }) {
    _unsubscribeDmPeerReadReceipts();

    void onPeerReadChange(PostgresChangePayload payload) {
      final row = payload.newRecord;
      final uid = (row['user_id'] ?? '').toString();
      if (uid != peerId) return;
      final raw = row['last_read_at'];
      DateTime? at;
      if (raw is DateTime) {
        at = raw.toUtc();
      } else if (raw is String && raw.isNotEmpty) {
        at = DateTime.tryParse(raw)?.toUtc();
      }
      if (!mounted) return;
      if (_peerLastReadAt == at) return;
      setState(() => _peerLastReadAt = at);
    }

    final filter = PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'chat_id',
      value: chatId,
    );

    _dmPeerReadsChannel = Supabase.instance.client
        .channel('dm:chat_reads:$chatId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'chat_reads',
          filter: filter,
          callback: onPeerReadChange,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_reads',
          filter: filter,
          callback: onPeerReadChange,
        )
        .subscribe();
  }

  void _unsubscribeDmPeerReadReceipts() {
    final ch = _dmPeerReadsChannel;
    _dmPeerReadsChannel = null;
    if (ch == null) return;
    try {
      ch.unsubscribe();
    } catch (_) {}
  }

  // ===== DM Draft helpers =====
  void _onTextChangedDm() {
    if (_editingMessage != null) return;
    if (_isDm) _saveDraftDmDebounced();
  }

  void _saveDraftDmDebounced() {
    _draftSaveTimerDm?.cancel();
    _draftSaveTimerDm = Timer(const Duration(milliseconds: 300), _saveDraftDm);
  }

  Future<void> _saveDraftDm() async {
    if (_isDm && !_dmComposerReady) return;
    if (_currentChatIdDm == null) return;
    final filesData = _att.pending
        .map((f) => {
              'localId': f.localId,
              'path': f.path,
              'name': f.name,
              'mimeType': f.mimeType,
              'size': f.size,
              'isImage': f.isImage,
              'preserveOriginal': f.preserveOriginal,
              'uploadStatus': f.uploadStatus.name,
              'progress': f.progress,
              'uploadedFileId': f.uploadedFileId,
            })
        .toList();
    await _globalCache.saveDraft(_currentChatIdDm!, _ctrl.text, filesData);
  }

  void _forceSaveDraftDm() {
    if (_editingMessage != null) return;
    _draftSaveTimerDm?.cancel();
    // ignore: discarded_futures
    _saveDraftDm();
  }

  void _restoreDraftDm() {
    if (_currentChatIdDm == null) return;
    final draft = _globalCache.getDraft(_currentChatIdDm!);
    if (draft == null) return;
    final (text, filesData) = draft;
    _ctrl.text = text;
    _att.pending
      ..clear()
      ..addAll(filesData.map((m) => LocalAttach(
            localId: m['localId'] as String?,
            path: m['path'] as String? ?? '',
            name: m['name'] as String? ?? '',
            mimeType: m['mimeType'] as String? ?? '',
            size: m['size'] as int? ?? 0,
            isImage: m['isImage'] as bool? ?? false,
            preserveOriginal: m['preserveOriginal'] as bool? ?? true,
            uploadStatus:
                ((m['uploadedFileId'] as String?)?.isNotEmpty ?? false)
                    ? LocalAttachUploadStatus.uploaded
                    : LocalAttachUploadStatus.failed,
            progress:
                ((m['uploadedFileId'] as String?)?.isNotEmpty ?? false) ? 1 : 0,
            errorMessage:
                ((m['uploadedFileId'] as String?)?.isNotEmpty ?? false)
                    ? null
                    : 'Не удалось загрузить',
            uploadedFileId: m['uploadedFileId'] as String?,
          )));
    if (mounted) setState(() {});
  }

  Future<void> _clearDraftDm() async {
    if (_currentChatIdDm != null) {
      await _globalCache.clearDraft(_currentChatIdDm!);
    }
  }

  Future<void> _prefetchOldFilesForDm() async {
    await _runAutoWork((current) async { try {
      final chatId = await widget.service.ensureChatId();
      if (!current()) return;
      final rows = await Supabase.instance.client
          .from('messages')
          .select('id, file_id')
          .eq('chat_id', chatId)
          .eq('msg_type', 'file')
          .not('file_id', 'is', null);

      if (!current()) return;

      for (final row in rows) {
        if (!current()) return;
        final fileId = row['file_id'] as String;
        final cached = _globalCache.getFile(fileId);
        if (cached != null) continue;

        final fileRow = await Supabase.instance.client
            .from('chat_files')
            .select('*')
            .eq('id', fileId)
            .eq('is_deleted', false)
            .maybeSingle();

        if (!current()) return;
        if (fileRow == null) continue;
        final chatFile = ChatFile.fromJson(fileRow);
        await _globalCache.cacheFile(fileId, chatFile);
        if (!current()) return;
      }
    } catch (_) {} });
  }

  Future<void> _initEntryBoundary() async {
    try {
      final unread = await widget.service.getUnreadMeta();
      DateTime? entry; // граница "видел до"
      bool showBadge = false; // показывать ли чип

      final count = (unread['unread_count'] ?? unread['count'] ?? 0) as int;
      final firstId = (unread['first_unread_id'] ?? '') as String?;
      final raw = unread['last_read_at'];

      DateTime? lastReadAt;
      if (raw is DateTime) {
        lastReadAt = raw.toUtc();
      } else if (raw is String && raw.isNotEmpty) {
        lastReadAt = DateTime.tryParse(raw)?.toUtc();
      }

      if (count > 0) {
        showBadge = true;
        if (lastReadAt != null) {
          entry = lastReadAt;
        } else if (firstId != null && firstId.isNotEmpty) {
          final list = widget.service.currentMessages;
          final idx = list.indexWhere((m) => m.id == firstId);
          if (idx >= 0) {
            entry =
                list[idx].at.toUtc().subtract(const Duration(microseconds: 1));
          } else if (list.isNotEmpty) {
            entry =
                list.first.at.toUtc().subtract(const Duration(microseconds: 1));
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _entrySeenAt = entry;
        _showEntryNewBadge = showBadge;
      });
    } catch (_) {}
  }

  // ---------- Forward Outbox ----------
  Future<void> _consumeForwardOutboxIfAny(String chatId, ForwardOutboxSession? outbox, {String? expectedExistingDraft, bool fromInitialization = false}) async {
    final uid=ChatFileAccess.userId, epoch=ChatFileAccess.generation;
    if (outbox == null || !outbox.isCurrent) return;
    if (_durableForwards) {
      bool currentTarget() => mounted && outbox.isCurrent && uid != null &&
          uid == ChatFileAccess.userId && epoch == ChatFileAccess.generation &&
          _currentChatIdDm == chatId;
      // Block sends until the durable slot has been inspected. Unknown results
      // must never be re-sent automatically after a restart.
      _durableBlocked = true;
      _legacyTextScope = null;
      _legacyTextOutbox = null;
      try {
        final durable = await ForwardOutboxHost.durable(context);
        if (!currentTarget()) return;
        final sentOperations = await outbox.terminalOperationsForChat(durable, chatId);
        if (!currentTarget()) return;
        if (_att.pending.any((file) => isTerminalForwardSentinel(file, sentOperations))) {
          _att.forgetConfirmedSent((file) => isTerminalForwardSentinel(file, sentOperations));
        }
        var receipt = await outbox.claimDurableForChat(chatId, durable);
        if (!currentTarget()) return;
        if (receipt == null) { _durableBlocked = false; return; }
        _durableOutbox = durable;
        _durableReceipt = receipt;
        if (receipt.state == DurableForwardState.sent) {
          await durable.acknowledgeSent(receipt);
          if (currentTarget() && identical(_durableReceipt, receipt)) {
            _att.forgetConfirmedSent((file) => isTerminalForwardSentinel(file, {receipt!.operation}));
            _durableReceipt = null;
            _durableBlocked = false;
          }
          return;
        }
        if (receipt.state == DurableForwardState.sendingUnknown || receipt.state == DurableForwardState.preparingUnknown) {
          final sending = receipt.state == DurableForwardState.sendingUnknown;
          final action = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
            title: Text(sending ? 'Отправка не подтверждена' : 'Подготовка прервана'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              DurableForwardPendingNotice(upload: !sending),
              const SizedBox(height: 12),
              Text(sending ? 'Проверьте чат. При повторной отправке сообщение может появиться дважды.' : 'Ранее загруженные файлы могли остаться на сервере.'),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, 'check'), child: const Text('Проверить чат')),
              TextButton(onPressed: () => Navigator.pop(dialogContext, 'cancel'), child: const Text('Удалить пересылку')),
              if (!sending) TextButton(onPressed: () => Navigator.pop(dialogContext, 'retry'), child: const Text('Повторить')),
            ],
          ));
          if (!currentTarget()) return;
          if (action == 'cancel') {
            final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
              title: const Text('Удалить сохранённую пересылку?'),
              content: Text(sending ? 'Сообщение уже могло быть отправлено. Запись о пересылке будет удалена с устройства.' : 'Загруженные ранее файлы могут остаться на сервере.'),
              actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Назад')),
                TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Удалить'))],
            ));
            if (confirmed != true || !currentTarget()) return;
            if (!identical(_durableReceipt, receipt)) return;
            final generation = _forwardPreparationGeneration;
            final staged = _stagedForward, attached = _forwardPackageAttached;
            final selected = List<String>.of(_forwardSelectedIds);
            final stagedIds = List<String>.of(_stagedForwardFileIds);
            final requiredIds = Set<String>.of(_requiredForwardFileIds);
            await durable.cancelByUser(receipt);
            await widget.debugAfterDurableCancel?.call();
            if (!currentTarget()) return;
            _att.forgetConfirmedSent((file) => isTerminalForwardSentinel(file, {receipt!.operation}));
            if (identical(_durableReceipt, receipt)) {
              _durableReceipt = null;
              _durableBlocked = false;
            }
            if (_forwardPreparationGeneration == generation && identical(_stagedForward, staged) &&
                _forwardPackageAttached == attached && listEquals(_forwardSelectedIds, selected) &&
                listEquals(_stagedForwardFileIds, stagedIds) && setEquals(_requiredForwardFileIds, requiredIds)) {
              setState(() {
                _forwardPackageAttached = false;
                _stagedForward = null;
                _forwardSelectedIds.clear();
                _stagedForwardFileIds.clear();
                _requiredForwardFileIds.clear();
              });
            }
          } else if (action == 'retry' && !sending) {
            await durable.retryPreparationByUser(receipt);
            if (currentTarget()) await _consumeForwardOutboxIfAny(chatId, outbox);
          }
          return;
        }
        bool composerAvailable() => (_ctrl.text.isEmpty ||
            (expectedExistingDraft != null && _ctrl.text == expectedExistingDraft &&
             expectedExistingDraft == (ForwardPayload.tryParse(receipt!.source)?.caption ?? ''))) &&
            _att.pending.isEmpty && _replyTo == null && !_forwardPackageAttached;
        if (!composerAvailable()) {
          _showSnack('Сохранённая пересылка ожидает: сначала завершите текущий черновик.');
          return;
        }
        bool Function()? sourceTicket;
        if (receipt.state == DurableForwardState.reservedUnverified || receipt.state == DurableForwardState.queued) {
          sourceTicket = receipt.state == DurableForwardState.queued
              ? outbox.consumeAutoApproval(durable, receipt) : null;
          if (sourceTicket == null) {
            final source = ForwardPayload.tryParse(receipt.source);
            if (source == null) throw const FormatException('Invalid forward');
            final approved = await confirmReadyForward(context, source, actionLabel: 'Подготовить');
            if (!approved || !currentTarget()) return;
          }
          if (receipt.state == DurableForwardState.reservedUnverified) {
            receipt = await durable.confirmReservation(receipt);
            if (!currentTarget()) return;
            _durableReceipt = receipt;
          }
        }
        if (receipt.state == DurableForwardState.ready) {
          final payload = ForwardPayload.tryParse(receipt.prepared ?? '');
          final preparedIds = receipt.preparedIds;
          if (payload == null || preparedIds == null) throw const FormatException('Invalid forward');
          final approved = await confirmReadyForward(context, payload);
          if (!approved || !currentTarget() || !identical(_durableReceipt, receipt)) return;
          if (!composerAvailable()) {
            _showSnack('Черновик изменился. Сохранённая пересылка ожидает проверки.');
            return;
          }
          if (!_att.pending.any((x) => x.path == '__FG__')) {
            _att.pending.add(LocalAttach(localId: 'durable-forward:${receipt.operation}', path: '__FG__', name: 'forward.json', mimeType: 'application/x-forward-group', size: 0, isImage: false));
          }
          setState(() {
            _stagedForward = payload;
            _forwardPackageAttached = true;
            _requiredForwardFileIds..clear()..addAll(preparedIds);
            _stagedForwardFileIds..clear()..addAll(preparedIds);
            _durableBlocked = false;
          });
          return;
        }
        final payload = ForwardPayload.tryParse(receipt.source);
        if (payload == null) throw const FormatException('Invalid forward');
        final preparing = await durable.markPreparing(receipt);
        if (!currentTarget()) return;
        _durableReceipt = preparing;
        if ((sourceTicket != null && !sourceTicket()) || _currentChatIdDm != chatId || !composerAvailable()) {
          _showSnack('Черновик изменился. Сохранённая пересылка ожидает проверки.');
          return;
        }
        await _stageForwardPayload(payload, receipt.sourceUrls, receipt.sourceIds, chatId, durablePreparation: true, sourceTicket: sourceTicket);
      } on LegacyForwardProvenanceUnknown {
        final binding = ChatFileAccess.currentSessionBinding;
        if (currentTarget() && binding != null) {
          _legacyTextScope = (uid!, epoch, chatId, binding);
          _legacyTextOutbox = outbox;
          _showSnack('Старая пересылка сохранена. Её происхождение не подтверждено.');
        }
      } catch (_) {
        if (currentTarget()) _showSnack('Пересылка сохранена, но пока недоступна.');
      }
      return;
    }
    ForwardOutboxData? data;
    try {
      data = await outbox.tryTakeForChat(chatId,
          requireQaHandoff: qaNoAutomaticWrites && fromInitialization);
    } catch (_) {
      if (outbox.isCurrent) _showSnack('Не удалось открыть сохранённую пересылку.');
      return;
    }
    if (data == null || !mounted || !outbox.isCurrent || uid!=ChatFileAccess.userId || epoch!=ChatFileAccess.generation) return;
    final raw = data.text ?? '';
    if (!ForwardPayload.isForwardText(raw)) return;
    final payload = ForwardPayload.tryParse(raw);
    if (payload == null) return;
    await _stageForwardPayload(payload, data.fileUrls, data.fileIds, chatId);
  }

  Future<void> _stageForwardPayload(ForwardPayload payload,
      List<String> fileUrls, List<String> fileIds, String chatId, {bool durablePreparation = false, bool Function()? sourceTicket}) async {
    final uid=ChatFileAccess.userId, epoch=ChatFileAccess.generation;
    bool sameSession() {
      try {
        return uid!=null && uid==ChatFileAccess.userId && epoch==ChatFileAccess.generation &&
            (!durablePreparation || _currentChatIdDm == chatId) && (sourceTicket?.call() ?? true);
      } catch (_) { return false; }
    }
    if (!mounted || !sameSession()) return;
    if (!forwardSourceReferencesComplete(payload, fileIds)) {
      throw const FormatException('Не все вложения готовы к пересылке.');
    }
    _requiredForwardFileIds.clear();

    // Existing file rows belong to the original message; even in this chat
    // the send RPC only accepts newly uploaded, unattached rows.
    final sameChat = !durablePreparation && payload.fromChatId == chatId;

    if (!_att.pending.any((x) => x.path == '__FG__')) {
      _att.pending.add(LocalAttach(
        localId: durablePreparation && _durableReceipt != null
            ? 'durable-forward:${_durableReceipt!.operation}' : null,
        path: '__FG__',
        name: 'forward.json',
        mimeType: 'application/x-forward-group',
        size: 0,
        isImage: false,
      ));
    }

    if ((payload.caption ?? '').isNotEmpty) {
      _ctrl.text = payload.caption!;
      _ctrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _ctrl.text.length),
      );
    } else {
      _ctrl.clear();
    }

    if (sameChat) {
      setState(() {
        _forwardPackageAttached = true;
        _stagedForward = null;
        _forwardSelectedIds
          ..clear()
          ..addAll(payload.items.map((e) => e.messageId));
        _stagedForwardFileIds.clear();
      });
      return;
    }

    final preparation = ++_forwardPreparationGeneration;
    setState(() {
      _forwardPackageAttached = true;
      _stagedForward = payload;
      _forwardSelectedIds.clear();
      _stagedForwardFileIds.clear();
      _preparingForward = true;
      _forwardPreparationFailed = false;
    });
    try {
      final refs = {for (final ref in payload.allFiles()) ref.url:ref};
      final urls = {...fileUrls.where((u)=>u.isNotEmpty), ...refs.keys};
      final copies = <String,ForwardFileRef>{};
      for (final url in urls) {
        if (!mounted || !sameSession() || preparation != _forwardPreparationGeneration) return;
        final copyOverride = widget.debugCopyForwardFile;
        if (copyOverride != null) {
          final source = refs[url];
          if (source == null) throw StateError('Missing source file');
          final copied = await copyOverride(source, chatId);
          if (!mounted || !sameSession() || preparation != _forwardPreparationGeneration) return;
          copies[url] = copied;
          continue;
        }
        final tmp = await _downloadToTemp(url);
        if (!mounted || !sameSession() || preparation != _forwardPreparationGeneration) { await ChatFileAccess.releaseForwardTemp(tmp.path); return; }
        final size=await tmp.length();
        if (!mounted || !sameSession() || preparation != _forwardPreparationGeneration) { await ChatFileAccess.releaseForwardTemp(tmp.path); return; }
        final source = refs[url];
        final attach = LocalAttach(path:tmp.path,
          name:source?.name ?? tmp.path.split(RegExp(r'[\\/]')).last,
          mimeType:source?.type ?? _guessMime(tmp.path),size:size,
          isImage:source?.type.startsWith('image/') ?? _isImagePath(tmp.path),
          preserveOriginal:true);
        if (!_att.add(attach)) { await ChatFileAccess.releaseForwardTemp(tmp.path); throw StateError('Слишком много вложений для одной пересылки.'); }
        await _att.upload(attach,chatId:chatId);
        if (!mounted || !sameSession() || preparation != _forwardPreparationGeneration) return;
        final ready = _att.pending.where((f)=>f.localId==attach.localId).firstOrNull;
        if (ready?.uploadedFileId == null) throw StateError('Не удалось подготовить вложение.');
        final row = await Supabase.instance.client.from('chat_files').select().eq('id',ready!.uploadedFileId!).single();
        if (!mounted || !sameSession() || preparation != _forwardPreparationGeneration) return;
        final copied = ChatFile.fromJson(row);
        copies[url] = ForwardFileRef(id:copied.id,url:copied.fileUrl,
            name:copied.fileName,type:copied.fileType,size:copied.fileSize);
      }
      if (mounted && sameSession() && preparation == _forwardPreparationGeneration) {
        final preparedIds = copies.values.map((file) => file.id).toList();
        if (preparedIds.any((id) => id == null || id.trim().isEmpty)) {
          throw StateError('Не все вложения готовы к пересылке.');
        }
        final preparedPayload = payload.withCopiedFiles(copies);
        if (durablePreparation) {
          final durable = _durableOutbox, receipt = _durableReceipt;
          if (durable == null || receipt == null) throw StateError('Forward unavailable');
          final confirmed = await durable.markReady(receipt, prepared: preparedPayload.encodeForText(), preparedIds: preparedIds.cast<String>(), uploadedIdsBySource: copies.map((key, value) => MapEntry(key, value.id!)));
          if (!mounted || !sameSession() || preparation != _forwardPreparationGeneration) return;
          _durableReceipt = confirmed;
          _durableBlocked = false;
        }
        setState(() {
          _requiredForwardFileIds
            ..clear()
            ..addAll(preparedIds.cast<String>());
          _stagedForwardFileIds
            ..clear()
            ..addAll(preparedIds.cast<String>());
          _stagedForward = preparedPayload;
        });
      }
    } catch (_) {
      if (mounted && sameSession() && preparation == _forwardPreparationGeneration) {
        setState(() => _forwardPreparationFailed = true);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:Text('Не удалось подготовить все вложения. Отмените пересылку и повторите.')));
      }
    } finally {
      if (mounted && sameSession() && preparation == _forwardPreparationGeneration) setState(() => _preparingForward=false);
    }
  }

  Future<File> _downloadToTemp(String url) => ChatFileAccess.forwardTemp(url);

  // ---------- Forward helpers ----------
  Future<List<String>> _waitUploads(List<String> paths,
      {int tries = 40}) async {
    var left = tries;
    while (left-- > 0) {
      final ready = <String>[];
      for (final p in paths) {
        final f = _att.pending.firstWhere(
          (x) => x.path == p,
          orElse: () => LocalAttach(
              path: '', name: '', mimeType: '', size: 0, isImage: false),
        );
        if ((f.path?.isNotEmpty ?? false) && f.uploadedFileId != null) {
          ready.add(f.uploadedFileId!);
        }
      }
      if (ready.length == paths.length) return ready;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return const [];
  }

  Future<void> _sendForwardHere(ForwardPayload payload, List<String> _) async {
    final replyId = _replyTo?.id;

    await widget.service.sendText(
      payload.encodeForText(),
      replyToId: replyId,
    );

    _att.clear();
    _ctrl.clear();
    setState(() {
      _replyTo = null;
      _forwardPackageAttached = false;
      _forwardPreparationGeneration++;
      _preparingForward = false;
      _forwardPreparationFailed = false;
      _stagedForward = null;
    });
    FocusScope.of(context).unfocus();
    await _clearDraftDm();
  }

  Future<void> _startForwardSelection(List<Message> selected, {VoidCallback? onPrepared}) async {
    if (selected.isEmpty) return;
    final outbox = ForwardOutbox.capture(context);
    if (outbox == null) return;
    final selectionSnapshot = ForwardSelectionSnapshot(selected);
    final sourceChat = _currentChatIdDm;
    final initialCaption = _ctrl.text;
    bool selectionCurrent() => mounted && outbox.isCurrent && (!_isDm || _currentChatIdDm == sourceChat) && selectionSnapshot.matches(widget.service.currentMessages);
    if (!selectionCurrent()) return;
    final initialSelection = Set<String>.of(_selectedIds);
    void preserveNewSelection() {
      if (selectionCurrent() && _selectedIds.length == initialSelection.length && _selectedIds.containsAll(initialSelection)) onPrepared?.call();
    }

    final items = <ForwardItem>[];
    final fileUrls = <String>[];
    final fileIds = <String>[];
    for (final m in selected..sort((a, b) => a.at.compareTo(b.at))) {
      final files = <ForwardFileRef>[];
      for (final f in (m.attachments ?? const <ChatFile>[])) {
        final url = (f.fileUrl ?? '');
        if (url.isNotEmpty) {
          files.add(ForwardFileRef(
              id: f.id,
              url: url,
              name: f.fileName,
              type: f.fileType,
              size: f.fileSize));
          fileUrls.add(url);
        }
        if (f.id.isNotEmpty) {
          fileIds.add(f.id);
        }
      }
      items.add(ForwardItem(
        messageId: m.id,
        authorId: m.authorId,
        authorName: m.authorName,
        authorAvatarUrl: m.authorAvatarUrl,
        at: m.at,
        text: m.text.trim(),
        files: files,
      ));
    }

    final fromChatId = await widget.service.ensureChatId();
    if (!selectionCurrent() || (_isDm && fromChatId != sourceChat)) return;
    final caption = initialCaption.trim().isEmpty ? null : initialCaption.trim();
    final payload =
        ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

    final uniqueFileUrls = fileUrls.where((u) => u.isNotEmpty).toSet().toList();
    final uniqueFileIds = fileIds.where((id) => id.isNotEmpty).toSet().toList();

    if (!selectionCurrent()) return;
    final target = await (widget.debugPickForwardTarget?.call(context, () => outbox.isCurrent) ??
        pickForwardTarget(context, isCurrent: () => outbox.isCurrent));
    if (target == null || !selectionCurrent()) return;

    final targetChatId = await _resolveForwardTargetChatId(target);
    if (!selectionCurrent()) return;
    if (_durableForwards && targetChatId == fromChatId) {
      try {
        final durable = await ForwardOutboxHost.durable(context);
        if (!selectionCurrent()) return;
        final saved = await completeForwardHandoff(
            prepare: () => outbox.putDurableForChat(durable, chatId: targetChatId,
                text: payload.encodeForText(), fileUrls: uniqueFileUrls,
                fileIds: uniqueFileIds, isSourceCurrent: selectionCurrent),
            isCurrent: selectionCurrent, onPrepared: preserveNewSelection);
        if (!saved || !selectionCurrent()) return;
        await _consumeForwardOutboxIfAny(targetChatId, outbox, expectedExistingDraft: initialCaption);
      } catch (_) {
        if (mounted && outbox.isCurrent) _showSnack('Не удалось сохранить пересылку. Выбор сохранён.');
      }
      return;
    }
    if (targetChatId == fromChatId) {
      // Всегда staged-чип, не вставляем сырой FG-текст
      await completeForwardHandoff(
          prepare: () => _stageForwardPayload(payload, uniqueFileUrls, uniqueFileIds, targetChatId),
          isCurrent: selectionCurrent, onPrepared: preserveNewSelection);
    } else {
      try {
        final ready = await completeForwardHandoff(
          prepare: () async {
            if (_durableForwards) {
              final durable = await ForwardOutboxHost.durable(context);
              if (!selectionCurrent()) throw StateError('Forward selection changed');
              await outbox.putDurableForChat(durable, chatId: targetChatId,
                  text: payload.encodeForText(), fileUrls: uniqueFileUrls, fileIds: uniqueFileIds,
                  isSourceCurrent: selectionCurrent);
            } else {
              await outbox.putForChat(chatId: targetChatId, text: payload.encodeForText(),
                  fileUrls: uniqueFileUrls, fileIds: uniqueFileIds, isSourceCurrent: selectionCurrent);
            }
          },
          isCurrent: selectionCurrent, onPrepared: preserveNewSelection);
        if (!ready) return;
      } catch (_) {
        if (outbox.isCurrent) _showSnack('Не удалось сохранить пересылку. Попробуйте ещё раз.');
        return;
      }
      if (!selectionCurrent()) return;
      await target.open(context);
    }
  }

  String _guessMime(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.pdf')) return 'application/pdf';
    return 'application/octet-stream';
  }

  bool _isImagePath(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.jpg') ||
        p.endsWith('.jpeg') ||
        p.endsWith('.png') ||
        p.endsWith('.gif') ||
        p.endsWith('.webp');
  }

  String? _forwardComposerPreview() => _stagedForward?.composerPreview();

  Future<void> _cancelDurableForward() async {
    if (_isSending) return;
    final durable = _durableOutbox, receipt = _durableReceipt;
    if (durable == null || receipt == null) return;
    final uid = ChatFileAccess.userId, epoch = ChatFileAccess.generation, chatId = _currentChatIdDm;
    bool sameTarget() => mounted && uid != null && chatId != null &&
        uid == ChatFileAccess.userId && epoch == ChatFileAccess.generation &&
        _currentChatIdDm == chatId;
    bool current() => sameTarget() && identical(receipt, _durableReceipt);
    final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Удалить сохранённую пересылку?'),
      content: const Text('Загруженные файлы могут остаться на сервере.'),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Назад')),
        TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Удалить'))],
    ));
    if (confirmed != true || !current()) return;
    _forwardPreparationGeneration++;
    final cancellationGeneration = _forwardPreparationGeneration;
    final staged = _stagedForward;
    final attached = _forwardPackageAttached;
    final selected = List<String>.of(_forwardSelectedIds);
    final stagedIds = List<String>.of(_stagedForwardFileIds);
    final requiredIds = Set<String>.of(_requiredForwardFileIds);
    _durableBlocked = true;
    try {
      await durable.cancelByUser(receipt);
      await widget.debugAfterDurableCancel?.call();
      if (!sameTarget()) return;
      setState(() {
        if (identical(receipt, _durableReceipt)) {
          _durableReceipt = null;
          _durableBlocked = false;
        }
        _att.pending.removeWhere((file) => isTerminalForwardSentinel(file, {receipt.operation}));
        if (_forwardPreparationGeneration == cancellationGeneration &&
            identical(_stagedForward, staged) && _forwardPackageAttached == attached &&
            listEquals(_forwardSelectedIds, selected) && listEquals(_stagedForwardFileIds, stagedIds) &&
            setEquals(_requiredForwardFileIds, requiredIds)) {
          _forwardPackageAttached = false;
          _preparingForward = false;
          _forwardPreparationFailed = false;
          _stagedForward = null;
          _forwardSelectedIds.clear();
          _stagedForwardFileIds.clear();
          _requiredForwardFileIds.clear();
        }
      });
    } catch (_) {
      if (current()) _showSnack('Не удалось удалить пересылку. Данные сохранены.');
    }
  }

  Future<String> _resolveForwardTargetChatId(ForwardTarget target) async {
    final id = target.chatId.trim();
    if (id.startsWith('dm_') && id.length > 3) {
      return DmApi.getOrCreateChatId(peerId: id.substring(3));
    }
    if (id.startsWith('team_') && id.length > 5) {
      final row = await Supabase.instance.client
          .from('chats')
          .select('id')
          .eq('team_id', id.substring(5))
          .eq('type', 'team_main')
          .limit(1)
          .maybeSingle();
      return (row?['id'] ?? '').toString();
    }
    return id;
  }

  Future<void> _sendForwardPayloadToTarget(
    ForwardTarget target,
    ForwardPayload payload,
  ) async {
    final chatId = await _resolveForwardTargetChatId(target);
    if (chatId.isEmpty) {
      throw StateError('Не удалось определить чат для пересылки');
    }
    await DmApi.sendText(
      chatId: chatId,
      text: payload.encodeForText(),
    );
  }

  // ---------- Scroll / Read ----------
  void _onScroll() {
    final show = !_chatScroll.atBottom();
    if (show != _showJump) {
      _showJump = show;
      if (mounted) setState(() {});
    }
    if (_isNearHistoryTop()) {
      _loadOlderMessages();
    }
    if (_chatScroll.atBottom()) {
      final list = widget.service.currentMessages;
      if (list.isNotEmpty) {
        final last = list.last;
        if (last.id != _lastMarkedReadId) _markReadSafely(last.id);
      }
    }
  }

  bool _isNearHistoryTop() {
    if (!_scroll.hasClients ||
        !_hasMoreOlderMessages ||
        _loadingOlderMessages) {
      return false;
    }
    final position = _scroll.position;
    return position.pixels >= position.maxScrollExtent - 240;
  }

  Future<void> _loadOlderMessages() async {
    if (_loadingOlderMessages || !_hasMoreOlderMessages) return;
    final list = widget.service.currentMessages;
    if (list.isEmpty) return;

    final oldest = list.reduce((a, b) => a.at.isBefore(b.at) ? a : b);
    final anchor = _chatScroll.capturePrependAnchor();
    _loadingOlderMessages = true;
    if (mounted) setState(() {});

    try {
      await widget.service.loadOlderMessages(before: oldest, limit: 50);
      _hasMoreOlderMessages = widget.service.messagesViewState.hasMoreBefore;
      await _chatScroll.restorePrependAnchor(anchor);
    } catch (_) {
      // Network/RPC failure: keep hasMore so scroll can retry.
    } finally {
      _loadingOlderMessages = false;
      if (mounted) setState(() {});
    }
  }

  void _onTyping() {
    _typingUsers.add('Вы');
    _myTypingOff?.cancel();
    _myTypingOff = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _typingUsers.remove('Вы');
    });
  }

  void _scheduleSeenCheck() {
    _seenDebounce?.cancel();
    _seenDebounce =
        Timer(const Duration(milliseconds: 150), _markLastSeenIfNeeded);
  }

  Future<void> _markLastSeenIfNeeded() async {
    if (!mounted) return;
    if (!_chatScroll.atBottom()) return;
    final list = widget.service.currentMessages;
    if (list.isEmpty) return;
    final last = list.last;
    if (last.id == _lastMarkedReadId) return;
    await _markReadSafely(last.id);
  }

  Future<void> _markReadSafely(String lastId) async {
    if (qaNoAutomaticWrites) return;
    if (lastId.isEmpty || lastId.startsWith('local_')) return;
    await _runAutoWork((current) async { try {
      await widget.service.markRead(lastId);
      if (!current()) return;
      _lastMarkedReadId = lastId;
      final chatId = _currentChatIdDm;
      if (chatId != null && chatId.isNotEmpty) {
        try {
          await AppNotificationsApi().markReadForChat(chatId);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[UnifiedChat] notification read sync error: $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[UnifiedChat] markRead error: $e');
    } });
  }

  Future<void> _jumpToBottom() async {
    await _chatScroll.jumpToBottom();
  }

  bool _canDelete(Message m) {
    final uid = widget.service.currentUserId;
    if (uid.isEmpty || m.authorId != uid) return false;
    return DateTime.now().difference(m.at) <= const Duration(hours: 12);
  }

  void _exitSelection() {
    _selectedIds.clear();
    if (!_selecting) return;
    setState(() => _selecting = false);
  }

  List<Message> _selectedMessagesFrom(List<Message> list) {
    final selected = list.where((m) => _selectedIds.contains(m.id)).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    return selected;
  }

  Future<void> _copySelectedMessages(List<Message> selected) async {
    if (selected.isEmpty) {
      _showSnack('Нечего копировать');
      return;
    }
    if (selected.length == 1) {
      try {
        await ca.ChatActions.copyMessageToClipboard(selected.first);
        _showSnack('Скопировано');
      } catch (_) {
        _showSnack('Не удалось скопировать');
      }
      return;
    }
    final text = selected
        .map((m) => m.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    if (text.isEmpty) {
      _showSnack('Нечего копировать');
      return;
    }
    await services.Clipboard.setData(services.ClipboardData(text: text));
    _showSnack('Скопировано');
  }

  Future<void> _deleteSelectedMessages(List<Message> selected) async {
    final deletable = selected.where(_canDelete).toList();
    if (deletable.isEmpty) {
      _showSnack(
        'Удалить можно только свои сообщения не старше 12 часов',
      );
      return;
    }

    final count = deletable.length;
    final skipped = selected.length - count;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(count == 1 ? 'Удалить сообщение?' : 'Удалить сообщения?'),
          content: Text(
            skipped > 0
                ? 'Будет удалено $count из ${selected.length}. Остальные нельзя удалить.'
                : (count == 1
                    ? 'Сообщение будет удалено для всех.'
                    : 'Будет удалено сообщений: $count.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: cs.error),
              child: const Text('Удалить'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    for (final m in deletable) {
      try {
        await widget.service.deleteMessage(m.id);
      } catch (_) {
        if (!mounted) return;
        _showSnack('Не удалось удалить сообщение');
        return;
      }
    }
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _forwardSelectedMessages(List<Message> selected) async {
    if (selected.isEmpty) return;
    await _startForwardSelection(selected, onPrepared: _exitSelection);
  }

  bool _canCopySelected(List<Message> selected) {
    if (selected.isEmpty) return false;
    if (selected.any((m) => m.text.trim().isNotEmpty)) return true;
    if (selected.length == 1 &&
        (selected.first.attachments?.isNotEmpty ?? false)) {
      return true;
    }
    return false;
  }

  bool _canEdit(Message m) =>
      canEditOwnTextMessage(m, widget.service.currentUserId);

  void _editMessage(Message m) {
    _beginInlineEdit(m);
  }

  void _beginInlineEdit(Message m) {
    if (!_canComposeDm) return;
    _draftSaveTimerDm?.cancel();
    setState(() {
      _editingMessage = m;
      _replyTo = null;
      _forwardPackageAttached = false;
      _forwardPreparationGeneration++;
      _preparingForward = false;
      _forwardPreparationFailed = false;
      _stagedForward = null;
      _forwardSelectedIds.clear();
      _stagedForwardFileIds.clear();
      _att.pending.removeWhere((file) => file.path == '__FG__');
      _ctrl.text = m.text;
      _ctrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _ctrl.text.length,
      );
    });
    _composerFocus.requestFocus();
    services.SystemChannels.textInput.invokeMethod('TextInput.show');
  }

  Future<void> _cancelInlineEdit({bool restoreDraft = true}) async {
    if (_editingMessage == null) return;
    _draftSaveTimerDm?.cancel();
    setState(() {
      _editingMessage = null;
      _ctrl.clear();
    });
    if (restoreDraft && _isDm) {
      _restoreDraftDm();
    }
  }

  Future<bool> _submitInlineEdit() async {
    final editing = _editingMessage;
    if (editing == null) return false;
    final nextText = _ctrl.text.trim();
    if (nextText.isEmpty) {
      _showSnack('Текст не может быть пустым');
      return true;
    }
    if (nextText.length > kChatMessageMaxLength) {
      _showSnack('Слишком длинный текст');
      return true;
    }
    if (nextText == editing.text.trim()) {
      await _cancelInlineEdit();
      return true;
    }

    _isSending = true;
    if (mounted) setState(() {});
    try {
      await widget.service.editOwnMessage(editing.id, nextText);
      if (!mounted) return true;
      setState(() {
        _editingMessage = null;
        _ctrl.clear();
      });
      if (_isDm) await _clearDraftDm();
    } catch (e) {
      _showSnack(friendlyEditMessageError(e));
    } finally {
      _isSending = false;
      if (mounted) setState(() {});
    }
    return true;
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  // ---------- Отправка ----------
  Future<void> _send(String text) async {
    if (_editingMessage != null) {
      await _submitInlineEdit();
      return;
    }
    if (_isUploadingAttachments || _hasFailedAttachments || _isSending) return;
    if (!_canComposeDm) return;
    final legacy = _legacyTextScope;
    bool plainText(String value) {
      if (value.contains('__FG__')) return false;
      final trimmed = value.trimLeft();
      if (!trimmed.startsWith('{')) return true;
      try {
        final decoded = jsonDecode(trimmed);
        return decoded is! Map ||
            (decoded['forward'] == null && decoded['from_chat_id'] == null);
      } on FormatException {
        return true;
      }
    }
    final plainLegacyText = legacy != null && (_legacyTextOutbox?.isCurrent ?? false) &&
        legacy.$1 == ChatFileAccess.userId && legacy.$2 == ChatFileAccess.generation &&
        legacy.$3 == _currentChatIdDm && legacy.$4 == ChatFileAccess.currentSessionBinding &&
        text.trim().isNotEmpty &&
        plainText(text) && _stagedForward == null &&
        !_forwardPackageAttached && _forwardSelectedIds.isEmpty &&
        _att.pending.isEmpty && _replyTo == null;
    if (_durableForwards && _durableBlocked && !plainLegacyText) {
      final chat = _currentChatIdDm;
      if (chat != null) {
        await _consumeForwardOutboxIfAny(chat, ForwardOutbox.capture(context));
      } else {
        _showSnack('Состояние пересылки ещё не подтверждено.');
      }
      return;
    }

    _isSending = true;
    final sendChat = _currentChatIdDm;
    final sendOwner = ChatFileAccess.userId;
    final sendEpoch = ChatFileAccess.generation;
    setState(() {});
    try {
      _forceSaveDraftDm();
      // 0) если висит staged forward — отправляем в этот чат
      if (_stagedForward != null && _forwardPackageAttached) {
        final forwardPayload = _stagedForward!;
        final owner = ChatFileAccess.userId;
        final session = ChatFileAccess.currentSessionBinding;
        final epoch = ChatFileAccess.generation;
        final preparation = _forwardPreparationGeneration;
        final composerText = _ctrl.text;
        final capturedReplyId = _replyTo?.id;
        final initialAttachments = ForwardAttachmentSnapshot(_att.pending);
        ForwardAttachmentSnapshot? sentAttachments;
        final target = _currentChatIdDm;
        bool sameForwardOperation() => mounted && owner != null && session != null && target != null &&
            owner == ChatFileAccess.userId && session == ChatFileAccess.currentSessionBinding &&
            epoch == ChatFileAccess.generation && _forwardPreparationGeneration == preparation &&
            _forwardPackageAttached && identical(_stagedForward, forwardPayload) &&
            _currentChatIdDm == target;
        bool currentForward() => sameForwardOperation() &&
            _ctrl.text == composerText && _replyTo?.id == capturedReplyId &&
            initialAttachments.sameFiles(_att.pending) &&
            (sentAttachments?.sameState(_att.pending) ?? true);
        if (!currentForward()) return;
        final forwardText = forwardPayload.encodeForText();
        final replyId = _replyTo?.id;

        // ждём загрузки всех реальных файлов (кроме чипа '__FG__')
        final pending = _att.pending.where((x) => x.path != '__FG__').toList();
        final collectedIds = <String>{};
        collectedIds.addAll(_stagedForwardFileIds);

        if (pending.isNotEmpty) {
          final paths = pending.map((f) => f.path).toList();
          const maxTries = 40;
          var tries = 0;
          while (tries < maxTries) {
            final ready = <String>[];
            for (final p in paths) {
              final f = _att.pending.firstWhere(
                (x) => x.path == p,
                orElse: () => LocalAttach(
                    path: '', name: '', mimeType: '', size: 0, isImage: false),
              );
              if (f.path.isNotEmpty && f.uploadedFileId != null) {
                ready.add(f.uploadedFileId!);
              }
            }
            if (ready.length == paths.length) {
              collectedIds.addAll(ready);
              break;
            }
            tries++;
            await Future.delayed(const Duration(milliseconds: 200));
            if (!currentForward()) return;
          }
        }

        final sent = await sendPreparedForwardIfComplete(
          requiredFiles: pending,
          currentFiles: _att.pending,
          stagedFileIds: _stagedForwardFileIds,
          expectedForwardFileIds: _requiredForwardFileIds,
          isCurrent: currentForward,
          send: (ids) async {
            sentAttachments = ForwardAttachmentSnapshot(_att.pending);
            final durable = _durableOutbox, receipt = _durableReceipt;
            if (_durableForwards) {
              if (receipt == null || durable == null) throw StateError('Forward unavailable');
              _durableBlocked = true;
              final confirmed = await durable.sendOnce(receipt,
                  text: forwardText, replyId: replyId, fileIds: ids,
                  send: (snapshot) {
                    if (!sameForwardOperation() || snapshot.chat != target) {
                      throw StateError('Chat changed');
                    }
                    return widget.service.sendText(snapshot.text,
                        replyToId: snapshot.replyId,
                        fileIds: snapshot.fileIds.isEmpty ? null : snapshot.fileIds);
                  });
              if (!sameForwardOperation()) return;
              _durableReceipt = confirmed;
              await durable.acknowledgeSent(confirmed);
              if (!sameForwardOperation() || !identical(_durableReceipt, confirmed)) return;
              _durableReceipt = null;
              _durableBlocked = false;
            } else {
              await widget.service.sendText(
                  forwardText, replyToId: replyId, fileIds: ids.isEmpty ? null : ids);
            }
          },
        );
        if (!sent) {
          if (currentForward()) _showSnack('Не все вложения готовы. Дождитесь загрузки или повторите её.');
          return;
        }
        if (!sameForwardOperation()) return;
        final sentSnapshot = sentAttachments!;
        _att.forgetConfirmedSent(sentSnapshot.containsUnchanged);
        setState(() {
          if (_replyTo?.id == capturedReplyId) _replyTo = null;
          _forwardPackageAttached = false;
          _forwardPreparationGeneration++;
          _preparingForward = false;
          _forwardPreparationFailed = false;
          _stagedForward = null;
          _forwardSelectedIds.clear();
          _stagedForwardFileIds.clear();
          _requiredForwardFileIds.clear();
          if (_ctrl.text == composerText) _ctrl.clear();
        });
        FocusScope.of(context).unfocus();
        // Keep any newer typed text or added files in the draft.
        if (_ctrl.text.isEmpty && _att.pending.isEmpty) await _clearDraftDm();
        else _forceSaveDraftDm();
        return;
      }

      // ---------- SAME-CHAT FORWARD (DM) ----------
      if (_forwardPackageAttached && _stagedForward == null) {
        final requestedIds = List<String>.of(_forwardSelectedIds);
        final selected = completeForwardSelection(requestedIds, widget.service.currentMessages);
        if (selected == null) {
          if (mounted) _showSnack('Часть сообщений или вложений недоступна. Выберите их снова.');
          return;
        }
        final selectionSnapshot = ForwardSelectionSnapshot(selected);
        final owner = ChatFileAccess.userId, session = ChatFileAccess.currentSessionBinding;
        final epoch = ChatFileAccess.generation, preparation = _forwardPreparationGeneration;
        final target = _currentChatIdDm, composerText = _ctrl.text, replyId = _replyTo?.id;
        bool sameSelectionOperation() => mounted && owner != null && session != null && target != null &&
            owner == ChatFileAccess.userId && session == ChatFileAccess.currentSessionBinding &&
            epoch == ChatFileAccess.generation && preparation == _forwardPreparationGeneration &&
            _forwardPackageAttached && _stagedForward == null && _currentChatIdDm == target &&
            _forwardSelectedIds.length == requestedIds.length &&
            _forwardSelectedIds.toSet().containsAll(requestedIds);
        bool currentSelection() => sameSelectionOperation() && _ctrl.text == composerText &&
            _replyTo?.id == replyId &&
            selectionSnapshot.matches(widget.service.currentMessages);
        if (!currentSelection()) return;

        // собираем мета для FG и оригинальные file_id
        final items = <ForwardItem>[];
        final fileIds = <String>[];
        for (final m in selected) {
          final files = <ForwardFileRef>[];
          for (final f in (m.attachments ?? const <ChatFile>[])) {
            final url = (f.fileUrl ?? '');
            if (url.isNotEmpty) {
              files.add(ForwardFileRef(
                  id: f.id,
                  url: url,
                  name: f.fileName,
                  type: f.fileType,
                  size: f.fileSize));
            }
            if (f.id.isNotEmpty) fileIds.add(f.id);
          }
          items.add(ForwardItem(
            messageId: m.id,
            authorId: m.authorId,
            authorName: m.authorName,
            authorAvatarUrl: m.authorAvatarUrl,
            at: m.at,
            text: m.text.trim(),
            files: files,
          ));
        }

        final fromChatId = await widget.service.ensureChatId();
        if (!currentSelection() || fromChatId != target) return;
        final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
        final payload = ForwardPayload(
            fromChatId: fromChatId, caption: caption, items: items);

        final uniqueFileIds = fileIds.toSet().toList();
        await widget.service.sendText(
          payload.encodeForText(),
          replyToId: _replyTo?.id,
          fileIds: uniqueFileIds.isEmpty ? null : uniqueFileIds,
        );
        if (!sameSelectionOperation()) return;
        final cleanup = confirmedForwardCleanup(sentText: composerText,
            currentText: _ctrl.text, sentReplyId: replyId, currentReplyId: _replyTo?.id);

        _att.pending.removeWhere((x) => x.path == '__FG__');
        if (cleanup.clearText) _ctrl.clear();
        setState(() {
          if (cleanup.clearReply) _replyTo = null;
          _forwardPackageAttached = false;
          _forwardPreparationGeneration++;
          _preparingForward = false;
          _forwardPreparationFailed = false;
          _forwardSelectedIds.clear();
        });
        FocusScope.of(context).unfocus();
        if (_ctrl.text.isEmpty && _att.pending.isEmpty) await _clearDraftDm();
        else _forceSaveDraftDm();
        return;
      }

      // 1) если есть пакет без staged (из текущего чата) — запустим выбор чата
      final trimmed = text.trim();
      if (_forwardPackageAttached) {
        await _handleForwardFlow();
        return;
      }

      if (trimmed.isEmpty && _att.pending.isEmpty) return;

      final replyId = _replyTo?.id;
      final files = _att.getPendingFiles();

      // Clear composer immediately so the bubble can appear without waiting
      // on the network round-trip (optimistic UI lives in DmApi.sendText).
      _ctrl.clear();
      final replyToClear = _replyTo;
      setState(() => _replyTo = null);
      FocusScope.of(context).unfocus();
      unawaited(_clearDraftDm());

      if (files.isNotEmpty) {
        final paths = files.map((f) => f.path).toList();
        const maxTries = 40;
        var tries = 0;
        List<String> fileIds = [];
        while (tries < maxTries) {
          final ready = <String>[];
          for (final p in paths) {
            final f = _att.pending.firstWhere(
              (x) => x.path == p,
              orElse: () => LocalAttach(
                  path: '', name: '', mimeType: '', size: 0, isImage: false),
            );
            if ((f.path?.isNotEmpty ?? false) && f.uploadedFileId != null) {
              ready.add(f.uploadedFileId!);
            }
          }
          if (ready.length == paths.length) {
            fileIds = ready;
            break;
          }
          tries++;
          await Future.delayed(const Duration(milliseconds: 200));
        }
        if (fileIds.isEmpty) {
          if (mounted) {
            _ctrl.text = trimmed;
            setState(() => _replyTo = replyToClear);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Файлы загружаются, подождите...')),
            );
          }
          return;
        }
        await widget.service
            .sendText(trimmed, replyToId: replyId, fileIds: fileIds);
        _att.clear();
      } else {
        await widget.service.sendText(trimmed, replyToId: replyId);
      }
    } catch (e) {
      if (_durableForwards && _durableBlocked && !plainLegacyText) {
        if (mounted && sendChat == _currentChatIdDm && sendOwner != null &&
            sendOwner == ChatFileAccess.userId && sendEpoch == ChatFileAccess.generation) {
          _showSnack('Отправка пересылки не подтверждена. Проверьте чат перед повтором.');
        }
        return;
      }
      if (_isDm && BlocksApi.isDmBlockedError(e)) {
        await _applyDmBlockedFromServer();
        return;
      }
      rethrow;
    } finally {
      _isSending = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _retryFailedDm(Message message) async {
    if (_durableForwards && _durableBlocked) {
      _showSnack('Сначала проверьте состояние сохранённой пересылки.');
      return;
    }
    final svc = widget.service;
    if (svc is! DmChatService) return;
    try {
      await svc.retryFailedText(message);
    } catch (e) {
      if (_isDm && BlocksApi.isDmBlockedError(e)) {
        await _applyDmBlockedFromServer();
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось отправить')),
        );
      }
    }
  }

  // ---------- Пересылка ----------
  Future<void> _handleForwardFlow() async {
    final outbox = ForwardOutbox.capture(context);
    if (outbox == null) return;
    final originalText = _ctrl.text;
    final originalSelection = Set<String>.of(_selectedIds);
    final originalForwardGeneration = _forwardPreparationGeneration;
    final originalForwardIds = List<String>.of(_forwardSelectedIds);
    final originalStagedForward = _stagedForward;
    final list = widget.service.currentMessages;
    final selected = completeForwardSelection(List.of(_forwardSelectedIds), list);
    if (selected == null) return;
    final selectionSnapshot = ForwardSelectionSnapshot(selected);
    final sourceChat = _currentChatIdDm;
    bool selectionCurrent() => mounted && outbox.isCurrent && (!_isDm || _currentChatIdDm == sourceChat) && selectionSnapshot.matches(widget.service.currentMessages);
    if (!selectionCurrent()) return;

    final items = <ForwardItem>[];
    final fileUrls = <String>[];
    final fileIds = <String>[];
    for (final m in selected) {
      final files = <ForwardFileRef>[];
      for (final f in (m.attachments ?? const <ChatFile>[])) {
        final url = (f.fileUrl ?? '');
        if (url.isNotEmpty) {
          files.add(ForwardFileRef(
              id: f.id,
              url: url,
              name: f.fileName,
              type: f.fileType,
              size: f.fileSize));
          fileUrls.add(url);
        }
        if (f.id.isNotEmpty) {
          fileIds.add(f.id);
        }
      }
      items.add(ForwardItem(
        messageId: m.id,
        authorId: m.authorId,
        authorName: m.authorName,
        authorAvatarUrl: m.authorAvatarUrl,
        at: m.at,
        text: m.text.trim(),
        files: files,
      ));
    }
    final fromChatId = await widget.service.ensureChatId();
    if (!selectionCurrent() || (_isDm && fromChatId != sourceChat)) return;
    final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
    final payload =
        ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

    final uniqueFileUrls = fileUrls.where((u) => u.isNotEmpty).toSet().toList();
    final uniqueFileIds = fileIds.where((id) => id.isNotEmpty).toSet().toList();

    if (!selectionCurrent()) return;
    final target = await (widget.debugPickForwardTarget?.call(context, () => outbox.isCurrent) ??
        pickForwardTarget(context, isCurrent: () => outbox.isCurrent));
    if (target == null || !selectionCurrent()) return;

    final targetChatId = await _resolveForwardTargetChatId(target);
    if (!selectionCurrent()) return;
    if (targetChatId == fromChatId) {
      if (_durableForwards) {
        final oldMarkers = _att.pending.where((file) => file.path == '__FG__').map((file) => file.localId).toSet();
        bool originalComposer() => selectionCurrent() && _ctrl.text == originalText &&
            originalText == (payload.caption ?? '') && _replyTo == null &&
            _forwardPreparationGeneration == originalForwardGeneration && _forwardPackageAttached &&
            listEquals(_forwardSelectedIds, originalForwardIds) && identical(_stagedForward, originalStagedForward) &&
            _durableReceipt == null && _att.pending.length == oldMarkers.length &&
            oldMarkers.isNotEmpty && _att.pending.every((file) => file.path == '__FG__' && oldMarkers.contains(file.localId));
        if (!originalComposer()) {
          _showSnack('Завершите текущий черновик перед пересылкой.');
          return;
        }
        try {
          final durable = await ForwardOutboxHost.durable(context);
          if (!originalComposer()) return;
          await outbox.putDurableForChat(durable, chatId: targetChatId,
              text: payload.encodeForText(), fileUrls: uniqueFileUrls,
              fileIds: uniqueFileIds, isSourceCurrent: originalComposer);
          if (!originalComposer()) return;
          setState(() {
            _att.pending.removeWhere((file) => file.path == '__FG__' && oldMarkers.contains(file.localId));
            _forwardPackageAttached = false;
            _forwardPreparationGeneration++;
            _forwardSelectedIds.clear();
            _stagedForwardFileIds.clear();
            _requiredForwardFileIds.clear();
          });
          await _consumeForwardOutboxIfAny(targetChatId, outbox, expectedExistingDraft: originalText);
        } catch (_) {
          if (mounted && outbox.isCurrent) _showSnack('Не удалось сохранить пересылку. Черновик сохранён.');
        }
        return;
      }
      await _stageForwardPayload(
        payload,
        uniqueFileUrls,
        uniqueFileIds,
        targetChatId,
      );
      return;
    }

    try {
      if (_durableForwards) {
        final durable = await ForwardOutboxHost.durable(context);
        if (!selectionCurrent()) throw StateError('Forward selection changed');
        await outbox.putDurableForChat(durable, chatId: targetChatId,
            text: payload.encodeForText(), fileUrls: uniqueFileUrls, fileIds: uniqueFileIds,
            isSourceCurrent: selectionCurrent);
      } else {
        await outbox.putForChat(chatId: targetChatId, text: payload.encodeForText(),
            fileUrls: uniqueFileUrls, fileIds: uniqueFileIds, isSourceCurrent: selectionCurrent);
      }
    } catch (_) {
      if (outbox.isCurrent) _showSnack('Не удалось сохранить пересылку. Попробуйте ещё раз.');
      return;
    }
    if (!selectionCurrent() || (_isDm && _currentChatIdDm != fromChatId)) return;

    setState(() {
      if (_forwardPreparationGeneration == originalForwardGeneration) {
        _forwardPackageAttached = false;
        _forwardPreparationGeneration++;
        _preparingForward = false;
        _forwardPreparationFailed = false;
        _stagedForward = null;
        _forwardSelectedIds.clear();
        _stagedForwardFileIds.clear();
      }
      // Очищаем выбор после подготовки FG-пакета
      if (_selectedIds.length == originalSelection.length && _selectedIds.containsAll(originalSelection)) {
        _selecting = false;
        _selectedIds.clear();
      }
      if (_ctrl.text == originalText) _ctrl.clear();
    });

    await target.open(context);
  }

  // ---------- Kebab («⋯») меню ----------
  Future<void> _openKebabMenu() async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final btnBox = _kebabKey.currentContext!.findRenderObject() as RenderBox;
    final target = RelativeRect.fromRect(
      Rect.fromPoints(
        btnBox.localToGlobal(Offset.zero, ancestor: overlay),
        btnBox.localToGlobal(btnBox.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<String>(
      context: context,
      position: target,
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'search',
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_rounded, size: 20),
              SizedBox(width: 10),
              Flexible(child: Text('Поиск сообщений')),
            ],
          ),
        ),
      ],
    );

    if (selected == 'search') {
      // ⚠️ фикс «первого нажатия»: принудительно перерисовываем экран
      setState(() {
        _search.setActive(true);
      });
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    if (!identical(widget.service, _screenService)) {
      return const Scaffold(body: Center(child: Text('Чат недоступен.')));
    }
    if (_initialCachedOnly) return _buildCachedDm(context);
    final titleText = widget.title == null || widget.title!.trim().isEmpty
        ? (widget.service.mode == ChatMode.dm ? kDmTitleFallback : 'Чат')
        : (widget.service.mode == ChatMode.dm
            ? normalizeDmTitle(widget.title)
            : widget.title!.trim());
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final theme = Theme.of(context);

    final isDm = widget.service.mode == ChatMode.dm;
    final caps = _composerCaps ??
        ChatComposerCapabilities.structuralLoading(
          teamKind: _teamKind(context),
          isDm: isDm,
        );
    final showPropose = !isDm &&
        widget.service.supportsAssignments &&
        caps.showProposeAssignment;
    final canProposeAssignments = showPropose && caps.canProposeAssignment;
    final showTopicSelection = !isDm && caps.showTopicSelection;
    final showCollection = !isDm && caps.showCollection;
    final topicEnabled = caps.canCreateTopicSelection;
    final collectionEnabled = caps.canCreateCollection;

    return Scaffold(
      appBar: _selecting
          ? PreferredSize(
              preferredSize: const Size.fromHeight(56),
              child: SafeArea(
                bottom: false,
                child: TopSelectionBar(
                  count: _selectedIds.length,
                  onClose: _exitSelection,
                  includeTopInset: false,
                ),
              ),
            )
          : AppBar(
              title: (isDm)
                  ? _DmTitle(
                      title: titleText,
                      avatarUrl: widget.peerAvatarUrl,
                      onTap: widget.onOpenPeer ??
                          () async {
                            final messages = widget.service.watchMessages();
                            await showModalBottomSheet(
                              context: context,
                              isScrollControlled: true,
                              useSafeArea: true,
                              backgroundColor: theme.colorScheme.surface,
                              builder: (_) =>
                                  ChatMediaSheet(messagesStream: messages),
                            );
                          },
                    )
                  : Text(titleText),
              centerTitle: false,
              iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkResponse(
                      key: _kebabKey,
                      radius: 22,
                      onTap: _openKebabMenu,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(Icons.more_horiz,
                            size: 24, color: theme.colorScheme.onSurface),
                      ),
                    ),
                  ),
                ),
              ],
            ),
      body: StreamBuilder<ChatMessagesViewState>(
        stream: _messagesStream,
        initialData: widget.service.messagesViewState.hasSnapshot ||
                widget.service.messagesViewState.messages.isNotEmpty
            ? widget.service.messagesViewState
            : null,
        builder: (ctx, snap) {
          final view = snap.data ?? widget.service.messagesViewState;
          final list = view.messages;
          // A known empty snapshot is still a snapshot: retain it while the
          // latest messages load. A cold miss must not pretend to be empty.
          final initialLoading = view.showInitialPlaceholder;
          final loadError = view.showError;

          if (_search.isActive) {
            _search.recompute(list, _isMatch);
          }

          if (list.isNotEmpty) {
            final newLastId = list.last.id;
            final changed = (newLastId != _lastRenderedLastId);
            _lastRenderedLastId = newLastId;
            if (changed && _chatScroll.nearBottom()) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _jumpToBottom();
                _scheduleSeenCheck();
              });
            }
          }

          final pins = list
              .where((m) => m.isPinned)
              .map((m) {
                final preview = ChatCardPreview.forPreview(m).trim();
                return PinEntry.message(
                  id: m.id,
                  title: 'Сообщение',
                  subtitle: preview.isEmpty ? null : preview,
                  messageId: m.id,
                );
              })
              .toList();

          return Column(
            children: [
              if (_search.isActive)
                InlineSearchBar(
                    controller: _search,
                    onClose: () => setState(() => _search.setActive(false)),
                )
              else if (!_selecting && pins.isNotEmpty)
                PinnedStripContainer(
                  pins: pins,
                  controller: _pinsCtl,
                  onOpen: (p) {
                    if (p.refId != null) _chatScroll.scrollToMessage(p.refId!);
                  },
                  onUnpin: (p) async {
                    if (p.type == PinType.message && p.refId != null) {
                      try {
                        await widget.service.pinMessage(p.refId!, false);
                      } catch (_) {
                        _showSnack('Не удалось открепить');
                      }
                    }
                  },
                ),

              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    if (_selecting) _exitSelection();
                  },
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: ChatMessageList(
                          messages: list,
                          controller: _scroll,
                          messageKeys: _messageKeys,
                          boundaryKeys: _bubbleBoundaryKeys,
                          search: _search,
                          currentUserId: widget.service.currentUserId,
                          entrySeenAt: _entrySeenAt,
                          showEntryNewBadge: _showEntryNewBadge,
                          hoveredMessageId: _hoveredMessageId,
                          noAvatarSpacing: isDm,
                          hideAuthorLine: isDm,
                          enableDmReceipts: isDm,
                          peerLastReadAt: isDm ? _peerLastReadAt : null,
                          onReply: (m) => setState(() => _replyTo = m),
                          onLongPress:
                              (ctx, m, rect, bytes, replyPreview, fallback) =>
                                  _showMessageActions(ctx, m,
                                      targetRect: rect,
                                      bubbleBytes: bytes,
                                      replyPreview: replyPreview,
                                      fallbackPosition: fallback),
                          onReplyTap: (id) => _chatScroll.scrollToMessage(id),
                          onReact: (ctx, id) =>
                              ca.ChatActions.showReactionPicker(
                                  ctx,
                                  (emoji) =>
                                      widget.service.toggleReaction(id, emoji)),
                          onReactionSelected: widget.service.toggleReaction,
                          canDeleteMessage: _canDelete,
                          canEditMessage: _canEdit,
                          onMenuAction: _handlePackageMenuAction,
                          selectingMessages: _selecting,
                          selectedMessageIds: _selectedIds,
                          onToggleSelect: (id) {
                            setState(() {
                              if (_selectedIds.contains(id))
                                _selectedIds.remove(id);
                              else
                                _selectedIds.add(id);
                              if (_selectedIds.isEmpty) _selecting = false;
                            });
                          },
                          // В ЛС аватары не показываем принципиально
                          forceHideAvatars: widget.hideAvatars || isDm,
                          isDirectChat: isDm,
                          canModerateTopicSelection:
                              _composerCaps?.canModerateTopicSelection,
                          canModerateCollection:
                              _composerCaps?.canModerateCollection,
                          canDeleteGroupAction:
                              _composerCaps?.canDeleteGroupAction,
                          canEditOwnBeforeActivity:
                              _composerCaps?.canEditOwnBeforeActivity,
                          onRetryFailedText:
                              isDm ? (m) => unawaited(_retryFailedDm(m)) : null,
                          onFocusComposer: () {
                            _composerFocus.requestFocus();
                            services.SystemChannels.textInput
                                .invokeMethod('TextInput.show');
                          },
                          onAttachFile: () async {
                            if (!_canComposeDm) return;
                            final file = await _fileService.pickFile();
                            if (file == null || !mounted) return;
                            final path = file.path;
                            final isImage = _isImagePath(path);
                            final attached = LocalAttach(
                              path: path,
                              name: path.split('/').last,
                              mimeType: _guessMime(path),
                              size: await file.length(),
                              isImage: isImage,
                            );
                            _att.add(attached);
                            final cid = await widget.service.ensureChatId();
                            _att.upload(attached, teamId: null, chatId: cid);
                            _saveDraftDmDebounced();
                          },
                          initialLoading: initialLoading,
                          loadError: loadError,
                          onRetryLoad: () {
                            unawaited(widget.service.retryLoadMessages());
                          },
                        ),
                      ),
                      if (_loadingOlderMessages)
                        const Positioned(
                          top: 8,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: ProductLoadingIndicator(),
                            ),
                          ),
                        ),
                      if (_showJump)
                        Positioned(
                          right: 12,
                          bottom: _selecting ? 20 : (safeBottom + 82.0),
                          child: ScrollToBottomButton(onTap: _jumpToBottom),
                        ),
                    ],
                  ),
                ),
              ),

              // Тонкая полоска статуса нужна только для реальной загрузки файлов.
              if (!_selecting && _editingMessage != null)
                _InlineEditBar(
                  message: _editingMessage!,
                  onCancel: _cancelInlineEdit,
                ),

              if (_selecting)
                Builder(
                  builder: (_) {
                    final selected = _selectedMessagesFrom(list);
                    final canDeleteAny = selected.any(_canDelete);
                    return BottomSelectionBar(
                      onCopy: _canCopySelected(selected)
                          ? () => unawaited(_copySelectedMessages(selected))
                          : null,
                      onForward: selected.isEmpty
                          ? null
                          : () => unawaited(
                                _forwardSelectedMessages(selected),
                              ),
                      onDelete: selected.isEmpty
                          ? null
                          : (canDeleteAny
                              ? () => unawaited(
                                    _deleteSelectedMessages(selected),
                                  )
                              : null),
                      deleteUnavailableHint:
                          'Удалить можно только свои сообщения не старше 12 часов',
                      onUnavailable: _showSnack,
                    );
                  },
                )
              else
                // ⚠️ ЛС и группы используют разные композеры
                (isDm && _dmBlockLoaded && !_dmAvailable)
                    ? _DmBlockedComposerBar(
                        iBlocked: _iBlockedPeer,
                        busy: _blockActionBusy || _chatInitializing,
                        onUnblock: _iBlockedPeer ? _unblockPeerFromDm : null,
                      )
                    : (isDm && !_dmComposerReady)
                        ? SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: _chatInitializationFailed
                                  ? TextButton(
                                      onPressed: _initializeChat,
                                      child: const Text(
                                          'Не удалось открыть чат. Повторить'),
                                    )
                                  : const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: ProductLoadingIndicator()),
                                        SizedBox(width: 12),
                                        Text('Подключение к чату…'),
                                      ],
                                    ),
                            ),
                          )
                        : (isDm)
                            ? DmComposerBar(
                                controller: _ctrl,
                                focusNode: _composerFocus,
                                replyTo: _replyTo,
                                onCloseReply: () =>
                                    setState(() => _replyTo = null),
                                forwardCount: _forwardPackageAttached
                                    ? (_stagedForward?.items.length ??
                                        _forwardSelectedIds.length)
                                    : 0,
                                forwardPreview: _forwardComposerPreview(),
                                onCancelForward: () {
                                  if (_durableForwards && _durableReceipt != null) { unawaited(_cancelDurableForward()); return; }
                                  setState(() {
                                    _forwardPackageAttached = false;
      _forwardPreparationGeneration++;
      _preparingForward = false;
      _forwardPreparationFailed = false;
                                    _stagedForward = null;
                                    _forwardSelectedIds.clear();
                                    _stagedForwardFileIds.clear();
                                    _att.pending
                                        .removeWhere((x) => x.path == '__FG__');
                                  });
                                },
                                // DM: typing UI is intentionally hidden until the feature is ready.
                                someoneTyping: false,
                                typingNames: const [],
                                attachedFiles: _att.pending
                                    .map((f) => AttachedFile(
                                          localId: f.localId,
                                          path: f.path,
                                          name: f.name,
                                          isImage: f.isImage,
                                          size: f.size,
                                          uploadStatus: f.uploadStatus,
                                          progress: f.progress,
                                          errorMessage: f.errorMessage,
                                          uploadedFileId: f.uploadedFileId,
                                        ))
                                    .toList(),
                                isUploading: _isUploadingAttachments,
                                hasFailedUploads: _hasFailedAttachments,
                                isSending: _isSending,
                                onAddFile: (ui) {
                                  if (!_canComposeDm) return;
                                  _att.add(LocalAttach(
                                    path: ui.path,
                                    name: ui.name,
                                    mimeType: ui.isImage
                                        ? 'image/jpeg'
                                        : 'application/octet-stream',
                                    size: ui.size,
                                    isImage: ui.isImage,
                                  ));
                                  _saveDraftDmDebounced();
                                },
                                onRemoveFile: (ui) {
                                  if (ui.path == '__FG__') {
                                    if (_durableForwards && _durableReceipt != null) { unawaited(_cancelDurableForward()); return; }
                                    setState(() {
                                      _forwardPackageAttached = false;
      _forwardPreparationGeneration++;
      _preparingForward = false;
      _forwardPreparationFailed = false;
                                      _stagedForward = null;
                                      _forwardSelectedIds.clear();
                                      _stagedForwardFileIds.clear();
                                      _att.pending.removeWhere(
                                          (x) => x.path == '__FG__');
                                    });
                                  } else {
                                    final local = _att.pending.firstWhere(
                                        (f) => f.localId == ui.localId);
                                    if (local.canCancel) {
                                      _att.cancel(local);
                                    } else {
                                      _att.remove(local);
                                    }
                                  }
                                  _saveDraftDmDebounced();
                                },
                                onRetryFile: (ui) async {
                                  if (!_canComposeDm) return;
                                  final local = _att.pending.firstWhere(
                                      (f) => f.localId == ui.localId);
                                  if (const bool.fromEnvironment('CHAT_ATTACHMENT_SESSION_FENCE_QA') &&
                                      await _retryAfterSessionChange(local)) return;
                                  if (!mounted) return;
                                  if (!_canComposeDm) return;
                                  final cid =
                                      await widget.service.ensureChatId();
                                  await _att.retry(local,
                                      teamId: null, chatId: cid);
                                  _saveDraftDmDebounced();
                                },
                                onSend: () => _send(_ctrl.text),
                                onPickImage: _pickPhotoForChat,
                                onOpenEmoji: () {
                                  if (!_canComposeDm) return;
                                  _composerFocus.requestFocus();
                                  services.SystemChannels.textInput
                                      .invokeMethod('TextInput.show');
                                },
                                onAttachFile: () async {
                                  if (!_canComposeDm) return;
                                  final file = await _fileService.pickFile();
                                  if (file != null) {
                                    final path = file.path;
                                    final attached = LocalAttach(
                                      path: path,
                                      name: path.split('/').last,
                                      mimeType: _guessMime(path),
                                      size: await file.length(),
                                      isImage: _isImagePath(path),
                                    );
                                    _att.add(attached);
                                    final cid =
                                        await widget.service.ensureChatId();
                                    _att.upload(attached,
                                        teamId: null, chatId: cid);
                                    _saveDraftDmDebounced();
                                  }
                                },
                                onPinText: (text) => _pinsCtl.pinText(text),
                              )
                            : ChatComposerBar(
                                controller: _ctrl,
                                focusNode: _composerFocus,
                                replyTo: _replyTo,
                                onCloseReply: () =>
                                    setState(() => _replyTo = null),
                                forwardCount: _forwardPackageAttached
                                    ? (_stagedForward?.items.length ??
                                        _forwardSelectedIds.length)
                                    : 0,
                                forwardPreview: _forwardComposerPreview(),
                                onCancelForward: () {
                                  if (_durableForwards && _durableReceipt != null) { unawaited(_cancelDurableForward()); return; }
                                  setState(() {
                                    _forwardPackageAttached = false;
      _forwardPreparationGeneration++;
      _preparingForward = false;
      _forwardPreparationFailed = false;
                                    _stagedForward = null;
                                    _forwardSelectedIds.clear();
                                    _stagedForwardFileIds.clear();
                                    _att.pending
                                        .removeWhere((x) => x.path == '__FG__');
                                  });
                                },
                                someoneTyping: _someoneTyping,
                                typingNames: _visibleTypingUsers,
                                attachedFiles: _att.pending
                                    .map((f) => AttachedFile(
                                          localId: f.localId,
                                          path: f.path,
                                          name: f.name,
                                          isImage: f.isImage,
                                          size: f.size,
                                          uploadStatus: f.uploadStatus,
                                          progress: f.progress,
                                          errorMessage: f.errorMessage,
                                          uploadedFileId: f.uploadedFileId,
                                        ))
                                    .toList(),
                                isUploading: _isUploadingAttachments,
                                hasFailedUploads: _hasFailedAttachments,
                                isSending: _isSending,
                                onAddFile: (ui) {
                                  _att.add(LocalAttach(
                                    path: ui.path,
                                    name: ui.name,
                                    mimeType: ui.isImage
                                        ? 'image/jpeg'
                                        : 'application/octet-stream',
                                    size: ui.size,
                                    isImage: ui.isImage,
                                  ));
                                },
                                onRemoveFile: (ui) {
                                  if (ui.path == '__FG__') {
                                    if (_durableForwards && _durableReceipt != null) { unawaited(_cancelDurableForward()); return; }
                                    setState(() {
                                      _forwardPackageAttached = false;
      _forwardPreparationGeneration++;
      _preparingForward = false;
      _forwardPreparationFailed = false;
                                      _stagedForward = null;
                                      _forwardSelectedIds.clear();
                                      _stagedForwardFileIds.clear();
                                      _att.pending.removeWhere(
                                          (x) => x.path == '__FG__');
                                    });
                                  } else {
                                    final local = _att.pending.firstWhere(
                                        (f) => f.localId == ui.localId);
                                    if (local.canCancel) {
                                      _att.cancel(local);
                                    } else {
                                      _att.remove(local);
                                    }
                                  }
                                },
                                onRetryFile: (ui) async {
                                  final local = _att.pending.firstWhere(
                                      (f) => f.localId == ui.localId);
                                  if (const bool.fromEnvironment('CHAT_ATTACHMENT_SESSION_FENCE_QA') &&
                                      await _retryAfterSessionChange(local)) return;
                                  if (!mounted) return;
                                  final cid =
                                      await widget.service.ensureChatId();
                                  await _att.retry(local,
                                      teamId: null, chatId: cid);
                                },
                                onSend: () => _send(_ctrl.text),
                                onPickImage: _pickPhotoForChat,
                                onOpenEmoji: () =>
                                    _composerFocus.requestFocus(),
                                onAttachFile: () async {
                                  final file = await _fileService.pickFile();
                                  if (file != null) {
                                    final path = file.path;
                                    final attached = LocalAttach(
                                      path: path,
                                      name: path.split('/').last,
                                      mimeType: _guessMime(path),
                                      size: await file.length(),
                                      isImage: _isImagePath(path),
                                    );
                                    _att.add(attached);
                                    final cid =
                                        await widget.service.ensureChatId();
                                    _att.upload(attached,
                                        teamId: null, chatId: cid);
                                  }
                                },
                                onPinText: (text) => _pinsCtl.pinText(text),
                                onFind: () async {
                                  FocusScope.of(context).unfocus();
                                  _search.setActive(true);
                                  setState(
                                      () {}); // на всякий случай перерисовка
                                },
                                showProposeInPlus: showPropose,
                                showTopicSelectionInPlus: showTopicSelection,
                                showCollectionInPlus: showCollection,
                                capabilitiesLoading: _capsLoading,
                                proposeEnabled: canProposeAssignments,
                                topicSelectionEnabled: topicEnabled,
                                collectionEnabled: collectionEnabled,
                                proposeDisabledReason:
                                    caps.reasonLabel('propose_assignment'),
                                topicSelectionDisabledReason:
                                    caps.reasonLabel('topic_selection'),
                                collectionDisabledReason:
                                    caps.reasonLabel('collection'),
                                onOpenTopicSelection: () =>
                                    unawaited(_openTopicSelection(context)),
                                onOpenCollection: () =>
                                    unawaited(_openCollection(context)),
                                onPropose: (title, description, link, due,
                                    attachments) async {
                                  if (!canProposeAssignments) return;
                                  await context
                                      .read<TeamCubit>()
                                      .proposeAssignment(
                                        title: title,
                                        description: description,
                                        link: link,
                                        due: due,
                                        attachments: attachments,
                                      );
                                },
                              ),
            ],
          );
        },
      ),
    );
  }

  /// QA-only safe fallback while existing bubble/media widgets do not yet
  /// support a strictly local-only access path.
  Widget _buildCachedDm(BuildContext context) {
    final service = _screenService as DmChatService;
    return ListenableBuilder(
      listenable: service.cachedAccessChanges!,
      builder: (context, _) {
        if (!service.canReadCached) {
          return const Scaffold(body: Center(child: Text('Сохранённый чат недоступен.')));
        }
        return Scaffold(
          appBar: AppBar(title: Text(normalizeDmTitle(widget.title ?? ''))),
          body: Column(children: [Expanded(child: StreamBuilder<ChatMessagesViewState>(
            stream: _messagesStream,
            initialData: service.messagesViewState,
            builder: (context, snapshot) {
              if (!service.canReadCached) return const SizedBox.shrink();
              final view = snapshot.data ?? service.messagesViewState;
              if (!view.hasSnapshot) {
                return Center(child: Text(view.showError
                    ? 'Сохранённые сообщения недоступны.' : 'Открываем сохранённые сообщения…'));
              }
              final messages = view.messages.where((m) =>
                  (m.cardKind?.trim().isEmpty ?? true) &&
                  !ChatCardPreview.looksLikeCardJson(m.text) &&
                  m.type != MessageType.assignmentDraft &&
                  m.type != MessageType.assignmentPublished).toList();
              if (messages.isEmpty) return Center(child: Text(view.messages.isEmpty
                  ? 'Сообщений пока нет' : 'Часть сообщений пока недоступна офлайн.'));
              return ChatMessageList(
                messages: messages,
                controller: _scroll,
                messageKeys: _messageKeys,
                search: _search,
                currentUserId: service.currentUserId,
                forceHideAvatars: true,
                noAvatarSpacing: true,
                hideAuthorLine: true,
                isDirectChat: true,
                showEntryNewBadge: false,
                selectingMessages: false,
                selectedMessageIds: const <String>{},
                onToggleSelect: null,
                onReply: (_) {},
                onLongPress: (_, __, ___, ____, _____, ______) {},
                onReplyTap: (_) {},
                onReact: (_, __) {},
                localOnlyBubbleBuilder: (message) => CachedChatMessageBubble(
                    message: message, service: service, showAuthor: false,
                    authorResolver: widget.cachedAuthorResolver),
              );
            },
          )), const CachedChatComposer()]),
        );
      },
    );
  }

  bool _canManageAssignments(BuildContext context) {
    try {
      return context.select((TeamCubit cubit) => cubit.state.isStarosta);
    } catch (_) {
      return false;
    }
  }

  String _teamKind(BuildContext context) {
    try {
      return context.select((TeamCubit cubit) => cubit.state.team.kind);
    } catch (_) {
      return 'subject';
    }
  }

  Future<void> _loadComposerCapabilities() async {
    if (!mounted) return;
    final isDm = widget.service.mode == ChatMode.dm;
    String teamKind = 'subject';
    bool isOrganizer = false;
    try {
      final st = context.read<TeamCubit>().state;
      teamKind = st.team.kind;
      isOrganizer = st.isStarosta;
    } catch (_) {}
    if (_composerCaps == null) {
      try {
        final chatId = await widget.service.ensureChatId();
        final cached = await _capsRepo.peekCache(chatId);
        if (!mounted) return;
        setState(() {
          _composerCaps = cached ??
              ChatComposerCapabilities.structuralLoading(
                teamKind: teamKind,
                isDm: isDm,
              );
          _capsLoading = cached == null;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _composerCaps = ChatComposerCapabilities.structuralLoading(
            teamKind: teamKind,
            isDm: isDm,
          );
          _capsLoading = true;
        });
      }
    } else {
      setState(() => _capsLoading = false);
    }
    try {
      final chatId = await widget.service.ensureChatId();
      final caps = await _capsRepo.load(
        chatId,
        fallbackTeamKind: teamKind,
        isDm: isDm,
        localIsOrganizer: isOrganizer,
      );
      if (!mounted) return;
      setState(() {
        _composerCaps = caps;
        _capsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _capsLoading = false);
    }
  }

  Future<void> _openTopicSelection(BuildContext context) async {
    if (_composerCaps?.canCreateTopicSelection != true) return;
    try {
      final teamId = context.read<TeamCubit>().state.team.id;
      final chatId = await SupabaseLearningRepository().getMainChatId(teamId);
      if (chatId.isEmpty || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CreateTopicSelectionScreen(chatId: chatId),
        ),
      );
      unawaited(_loadComposerCapabilities());
    } catch (_) {}
  }

  Future<void> _openCollection(BuildContext context) async {
    if (_composerCaps?.canCreateCollection != true) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CreateCollectionScreen()),
    );
    unawaited(_loadComposerCapabilities());
  }

  void _showMessageActions(BuildContext ctx, Message m,
      {Rect? targetRect,
      Uint8List? bubbleBytes,
      String? replyPreview,
      Offset? fallbackPosition}) async {
    Rect? finalRect = targetRect;
    if (finalRect == null) {
      final bubbleKey = _bubbleBoundaryKeys[m.id];
      if (bubbleKey?.currentContext != null) {
        final renderObject = bubbleKey!.currentContext!.findRenderObject();
        if (renderObject is RenderBox && renderObject.hasSize) {
          final overlayBox = Overlay.of(ctx, rootOverlay: true)
              .context
              .findRenderObject() as RenderBox;
          final topLeft = renderObject.localToGlobal(
            Offset.zero,
            ancestor: overlayBox,
          );
          finalRect = topLeft & renderObject.size;
        }
      }
    }

    setState(() => _hoveredMessageId = m.id);
    try {
      await ca.ChatActions.showMessageActions(
        ctx,
        m,
        targetRect: finalRect,
        bubbleBytes: bubbleBytes,
        replyPreview: replyPreview,
        fallbackPosition: fallbackPosition,
        onReply: () => setState(() => _replyTo = m),
        onForward: () async {
          await _startForwardSelection([m]);
        },
        onTogglePin: () async {
          try {
            await widget.service.pinMessage(m.id, !m.isPinned);
          } catch (_) {
            _showSnack(
                m.isPinned ? 'Не удалось открепить' : 'Не удалось закрепить');
          }
        },
        onDeleteIfAllowed: () async => widget.service.deleteMessage(m.id),
        onEditIfAllowed: _canEdit(m)
            ? () async {
                _editMessage(m);
              }
            : null,
        onReact: (emoji) => widget.service.toggleReaction(m.id, emoji),
        onSelect: () {
          _selectedIds.add(m.id);
          setState(() => _selecting = true);
        },
      );
    } finally {
      if (mounted) setState(() => _hoveredMessageId = null);
    }
  }

  Future<void> _handlePackageMenuAction(Message m, String action) async {
    switch (action) {
      case 'Ответить':
        setState(() => _replyTo = m);
        break;
      case 'Скопировать':
        await ca.ChatActions.copyMessageToClipboard(m);
        break;
      case 'Изменить':
        if (_canEdit(m)) {
          _editMessage(m);
        }
        break;
      case 'Закрепить':
      case 'Открепить':
        try {
          await widget.service.pinMessage(m.id, !m.isPinned);
        } catch (_) {
          _showSnack(
              m.isPinned ? 'Не удалось открепить' : 'Не удалось закрепить');
        }
        break;
      case 'Переслать':
        await _startForwardSelection([m]);
        break;
      case 'Удалить':
        if (_canDelete(m)) {
          await widget.service.deleteMessage(m.id);
        }
        break;
      case 'Выбрать':
        _selectedIds.add(m.id);
        setState(() => _selecting = true);
        break;
    }
  }

  bool _isMatch(Message m, String query) {
    if (query.isEmpty) return false;
    final q = query.toLowerCase().trim();
    if (m.text.toLowerCase().contains(q)) return true;
    if (m.authorName.toLowerCase().contains(q)) return true;
    if (m.authorLogin.toLowerCase().contains(q)) return true;
    for (final f in (m.attachments ?? const <ChatFile>[])) {
      if (f.fileName.toLowerCase().contains(q)) return true;
      final ext = f.fileName.split('.').last.toLowerCase();
      if (ext.contains(q)) return true;
    }
    final ts =
        '${m.at.hour.toString().padLeft(2, '0')}:${m.at.minute.toString().padLeft(2, '0')}';
    if (ts.contains(q)) return true;
    final words = q.split(' ');
    if (words.length > 1) {
      final textLower = m.text.toLowerCase();
      final authorLower = m.authorName.toLowerCase();
      bool all = true;
      for (final w in words) {
        if (w.length > 2 &&
            !textLower.contains(w) &&
            !authorLower.contains(w)) {
          all = false;
          break;
        }
      }
      if (all) return true;
    }
    return false;
  }
}

class _InlineEditBar extends StatelessWidget {
  const _InlineEditBar({
    required this.message,
    required this.onCancel,
  });

  final Message message;
  final Future<void> Function() onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = message.text.trim();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.edit_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Редактирование',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (preview.isNotEmpty)
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.62),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Отменить редактирование',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => onCancel(),
          ),
        ],
      ),
    );
  }
}

class _DmBlockedComposerBar extends StatelessWidget {
  const _DmBlockedComposerBar({
    required this.iBlocked,
    required this.busy,
    this.onUnblock,
  });

  final bool iBlocked;
  final bool busy;
  final Future<void> Function()? onUnblock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = iBlocked
        ? 'Вы заблокировали пользователя'
        : 'Личные сообщения недоступны';

    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final bottomPad =
        safeBottom > 0 ? (safeBottom - 12).clamp(18.0, safeBottom) : 6.0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomPad),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outline.withValues(alpha: 0.22)),
        ),
        child: Row(
          children: [
            Icon(Icons.block, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (iBlocked && onUnblock != null)
              TextButton(
                onPressed: busy ? null : () => onUnblock!.call(),
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: ProductLoadingIndicator(),
                      )
                    : const Text('Разблокировать'),
              ),
          ],
        ),
      ),
    );
  }
}

class _DmTitle extends StatelessWidget {
  const _DmTitle({required this.title, this.avatarUrl, required this.onTap});
  final String title;
  final String? avatarUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: colors.primaryContainer,
            backgroundImage: (avatarUrl != null && avatarUrl!.isNotEmpty)
                ? CachedNetworkImageProvider(avatarUrl!) as ImageProvider
                : null,
            child: (avatarUrl == null || avatarUrl!.isEmpty)
                ? Icon(Icons.person_outline_rounded, size: 20, color: colors.onPrimaryContainer)
                : null,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: colors.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
