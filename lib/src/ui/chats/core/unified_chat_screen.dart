// FILE: lib/src/ui/chats/core/unified_chat_screen.dart
// ignore_for_file: unnecessary_import, unused_import, unused_field, unused_element, dead_null_aware_expression, invalid_null_aware_operator, deprecated_member_use

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart' as services;

import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';

import 'package:student_platform/src/ui/learning/tabs/chat/actions/chat_actions.dart' as ca;
import 'package:student_platform/src/ui/learning/tabs/chat/widgets.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/inline_search_bar.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/selection_bars.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';

import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/ui/learning/global_cache.dart';
import 'package:student_platform/src/services/image_cache_service.dart';

import '../media/chat_media_sheet.dart';
import '../forward/forward_picker.dart';
import '../forward/forward_pick_nav.dart';
import 'forward_payload.dart';
import '../forward/forward_outbox.dart';
import '../data/dm_api.dart';

import 'i_chat_service.dart';

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
  });

  final IChatService service;
  final String? title;
  final bool hideAvatars;

  // для ЛС
  final String? peerAvatarUrl;
  final VoidCallback? onOpenPeer;

  @override
  State<UnifiedChatScreen> createState() => _UnifiedChatScreenState();
}

class _UnifiedChatScreenState extends State<UnifiedChatScreen> {
  final _scroll = ScrollController();
  final _ctrl = TextEditingController();
  final _composerFocus = FocusNode();

  late final ChatScrollController _chatScroll;
  late final ChatSearchController _search;
  late final PinController _pinsCtl;
  late final ChatAttachmentsController _att;

  final FileService _fileService = FileService();
  final GlobalCache _globalCache = GlobalCache();
  final AppImageCache _imgCache = AppImageCache();

  final Map<String, GlobalKey> _messageKeys = {};
  final Map<String, GlobalKey> _bubbleBoundaryKeys = {};
  void _pruneMessageKeys(Set<String> aliveIds) =>
      _messageKeys.removeWhere((id, _) => !aliveIds.contains(id));
  String? _hoveredMessageId;

  bool _showJump = false;
  bool _loadingOlderMessages = false;
  bool _hasMoreOlderMessages = true;
  Message? _replyTo;

  final Set<String> _typingUsers = {};
  Timer? _myTypingOff;
  bool get _someoneTyping => _typingUsers.isNotEmpty;

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

  bool _selecting = false;
  final Set<String> _selectedIds = {};

  bool _forwardPackageAttached = false;
  final List<String> _forwardSelectedIds = [];
  final List<String> _stagedForwardFileIds = [];
  ForwardPayload? _stagedForward;

  // Блокировка повторных отправок и индикатор фоновых загрузок
  bool _isSending = false;
  bool get _isUploadingAttachments =>
      _att.pending.any((f) => f.path != '__FG__' && (f.uploadedFileId == null));

  // якорь для «⋯»
  final GlobalKey _kebabKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _chatScroll = ChatScrollController(_scroll, _messageKeys);
    _search = ChatSearchController();
    _pinsCtl = PinController();
    _att = ChatAttachmentsController(_fileService, _globalCache, Supabase.instance.client)
      ..addListener(() {
        if (!mounted) return;
        setState(() {});
        if (_isDm) _saveDraftDmDebounced();
      });

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

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cid = await widget.service.ensureChatId();
      _currentChatIdDm = cid;
      _restoreDraftDm();
      await _initEntryBoundary();
      await _consumeForwardOutboxIfAny(cid);
      // smooth previews like in ChatTab
      // ignore: discarded_futures
      _prefetchOldFilesForDm();
      await _jumpToBottom();
      // Сразу сбрасываем непрочитанные, если реально внизу и есть сообщения
      final list = widget.service.currentMessages;
      if (list.isNotEmpty && _chatScroll.atBottom()) {
        // ignore: discarded_futures
        _markReadSafely(list.last.id);
      }
    });

    // Optional: handle keyboard image paste like ChatTab
    _keyboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onKeyboardImagePicked' || call.method == 'onPicked') {
        final path = (call.arguments ?? '') as String;
        if (path.isNotEmpty && mounted) {
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

  @override
  void dispose() {
    try {
      final list = widget.service.currentMessages;
      if (list.isNotEmpty) _markReadSafely(list.last.id);
    } catch (_) {}
    _forceSaveDraftDm();
    _seenDebounce?.cancel();
    _scroll.removeListener(_onScroll);
    if (_typingHookAttached) {
      _ctrl.removeListener(_onTyping);
    }
    if (_dmTextHookAttached) {
      _ctrl.removeListener(_onTextChangedDm);
    }
    try { _keyboardChannel.invokeMethod('dispose'); } catch (_) {}
    _keyboardChannel.setMethodCallHandler(null);
    _scroll.dispose();
    _ctrl.dispose();
    _composerFocus.dispose();
    _myTypingOff?.cancel();
    super.dispose();
  }

  // ===== DM Draft helpers =====
  void _onTextChangedDm() {
    if (_isDm) _saveDraftDmDebounced();
  }

  void _saveDraftDmDebounced() {
    _draftSaveTimerDm?.cancel();
    _draftSaveTimerDm = Timer(const Duration(milliseconds: 300), _saveDraftDm);
  }

  Future<void> _saveDraftDm() async {
    if (_currentChatIdDm == null) return;
    final filesData = _att.pending.map((f) => {
      'path': f.path ?? '',
      'name': f.name ?? '',
      'mimeType': f.mimeType ?? '',
      'size': f.size ?? 0,
      'isImage': f.isImage ?? false,
      'uploadedFileId': f.uploadedFileId,
    }).toList();
    await _globalCache.saveDraft(_currentChatIdDm!, _ctrl.text, filesData);
  }

  void _forceSaveDraftDm() {
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
        path: m['path'] as String? ?? '',
        name: m['name'] as String? ?? '',
        mimeType: m['mimeType'] as String? ?? '',
        size: m['size'] as int? ?? 0,
        isImage: m['isImage'] as bool? ?? false,
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
    try {
      final chatId = await widget.service.ensureChatId();
      final rows = await Supabase.instance.client
          .from('messages')
          .select('id, file_id')
          .eq('chat_id', chatId)
          .eq('msg_type', 'file')
          .not('file_id', 'is', null);

      for (final row in rows) {
        final fileId = row['file_id'] as String;
        final cached = _globalCache.getFile(fileId);
        if (cached != null) continue;

        final fileRow = await Supabase.instance.client
            .from('chat_files')
            .select('*')
            .eq('id', fileId)
            .eq('is_deleted', false)
            .maybeSingle();

        if (fileRow == null) continue;
        final chatFile = ChatFile.fromJson(fileRow);
        await _globalCache.cacheFile(fileId, chatFile);

        if ((chatFile.fileType).startsWith('image/') && chatFile.fileUrl.isNotEmpty) {
          // ignore: discarded_futures
          precacheImage(CachedNetworkImageProvider(chatFile.fileUrl), context);
        }
      }
    } catch (_) {}
  }

  Future<void> _initEntryBoundary() async {
    try {
      final unread = await widget.service.getUnreadMeta();
      DateTime? entry;            // граница "видел до"
      bool showBadge = false;     // показывать ли чип

      final count   = (unread['unread_count'] ?? unread['count'] ?? 0) as int;
      final firstId = (unread['first_unread_id'] ?? '') as String?;
      final raw     = unread['last_read_at'];

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
            entry = list[idx].at.toUtc().subtract(const Duration(microseconds: 1));
          } else if (list.isNotEmpty) {
            entry = list.first.at.toUtc().subtract(const Duration(microseconds: 1));
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
  Future<void> _consumeForwardOutboxIfAny(String chatId) async {
    final data = await ForwardOutbox.tryTakeForChat(chatId);
    if (data == null) return;
    final raw = data.text ?? '';
    if (!ForwardPayload.isForwardText(raw)) return;
    final payload = ForwardPayload.tryParse(raw);
    if (payload == null) return;
    await _stageForwardPayload(payload, data.fileUrls, data.fileIds, chatId);
  }

  Future<void> _stageForwardPayload(ForwardPayload payload, List<String> fileUrls, List<String> fileIds, String chatId) async {
    if (!mounted) return;

    final sameChat = (payload.fromChatId == chatId);

    if (!_att.pending.any((x) => x.path == '__FG__')) {
      _att.pending.add(LocalAttach(
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

    final uniqueIds = fileIds.where((id) => id.isNotEmpty).toSet().toList();
    if (uniqueIds.isNotEmpty) {
      setState(() {
        _forwardPackageAttached = true;
        _stagedForward = payload;
        _forwardSelectedIds.clear();
        _stagedForwardFileIds
          ..clear()
          ..addAll(uniqueIds);
      });
      return;
    }

    final uniqueUrls = fileUrls.where((u) => u.isNotEmpty).toSet();
    if (uniqueUrls.isEmpty) {
      setState(() {
        _forwardPackageAttached = true;
        _stagedForward = payload;
        _forwardSelectedIds.clear();
        _stagedForwardFileIds.clear();
      });
      return;
    }

    setState(() {
      _forwardPackageAttached = true;
      _stagedForward = payload;
      _forwardSelectedIds.clear();
      _stagedForwardFileIds.clear();
    });

    for (final url in uniqueUrls) {
      try {
        final tmp = await _downloadToTemp(url);
        final attach = LocalAttach(
          path: tmp.path,
          name: tmp.path.split('/').last,
          mimeType: _guessMime(tmp.path),
          size: await tmp.length(),
          isImage: _isImagePath(tmp.path),
        );
        if (!mounted) return;
        _att.add(attach);
        // ignore: unawaited_futures
        _att.upload(attach, teamId: null, chatId: chatId);
      } catch (e) {
        if (kDebugMode) debugPrint('[Forward/stage DM] $e');
      }
    }
  }



  Future<File> _downloadToTemp(String url) async {
    final http = HttpClient();
    final req = await http.getUrl(Uri.parse(url));
    final resp = await req.close();
    final bytes = await consolidateHttpClientResponseBytes(resp);
    final dir = await Directory.systemTemp.createTemp('sp_forward_');
    final name = url.split('?').first.split('/').last;
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  // ---------- Forward helpers ----------
  Future<List<String>> _waitUploads(List<String> paths, {int tries = 40}) async {
    var left = tries;
    while (left-- > 0) {
      final ready = <String>[];
      for (final p in paths) {
        final f = _att.pending.firstWhere(
          (x) => x.path == p,
          orElse: () => LocalAttach(path: '', name: '', mimeType: '', size: 0, isImage: false),
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

    // ждём аплоада всех pending (кроме '__FG__')
    final files = _att.pending.where((x) => x.path != '__FG__').toList();
    List<String> fileIds = [];
    if (files.isNotEmpty) {
      final paths = files.map((f) => f.path).toList();
      fileIds = await _waitUploads(paths, tries: 60);
    }

    await widget.service.sendText(
      payload.encodeForText(),
      replyToId: replyId,
      fileIds: fileIds.isEmpty ? null : fileIds,
    );

    _att.clear();
    _ctrl.clear();
    setState(() {
      _replyTo = null;
      _forwardPackageAttached = false;
      _stagedForward = null;
    });
    FocusScope.of(context).unfocus();
    await _clearDraftDm();
  }

  Future<void> _startForwardSelection(List<Message> selected) async {
    if (selected.isEmpty) return;

    final items = <ForwardItem>[];
    final fileUrls = <String>[];
    final fileIds = <String>[];
    for (final m in selected..sort((a,b)=>a.at.compareTo(b.at))) {
      final files = <ForwardFileRef>[];
      for (final f in (m.attachments ?? const <ChatFile>[])) {
        final url = (f.fileUrl ?? '');
        if (url.isNotEmpty) {
          files.add(ForwardFileRef(id: f.id, url: url, name: f.fileName, type: f.fileType, size: f.fileSize));
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
    final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
    final payload = ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

    final uniqueFileUrls = fileUrls.where((u) => u.isNotEmpty).toSet().toList();
    final uniqueFileIds = fileIds.where((id) => id.isNotEmpty).toSet().toList();

    final target = await pickForwardTarget(context);
    if (target == null) return;

    if (target.chatId == fromChatId) {
      // Всегда staged-чип, не вставляем сырой FG-текст
      await _stageForwardPayload(payload, uniqueFileUrls, uniqueFileIds, fromChatId);
    } else {
      await ForwardOutbox.putForChat(
        chatId: target.chatId,
        text: payload.encodeForText(),
        fileUrls: uniqueFileUrls,
        fileIds: uniqueFileIds,
      );
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
    return p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.png') || p.endsWith('.gif') || p.endsWith('.webp');
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
    if (!_scroll.hasClients || !_hasMoreOlderMessages || _loadingOlderMessages) {
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
    _loadingOlderMessages = true;
    if (mounted) setState(() {});

    try {
      final loaded = await widget.service.loadOlderMessages(before: oldest, limit: 50);
      if (loaded.length < 50) {
        _hasMoreOlderMessages = false;
      }
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
    _seenDebounce = Timer(const Duration(milliseconds: 150), _markLastSeenIfNeeded);
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
    try {
      await widget.service.markRead(lastId);
      _lastMarkedReadId = lastId;
    } catch (e) {
      if (kDebugMode) debugPrint('[UnifiedChat] markRead error: $e');
    }
  }

  Future<void> _jumpToBottom() async {
    await _chatScroll.jumpToBottom();
  }

  bool _canDelete(Message m) {
    final uid = widget.service.currentUserId;
    if (uid.isEmpty || m.authorId != uid) return false;
    return DateTime.now().difference(m.at) <= const Duration(hours: 12);
  }

  // ---------- Отправка ----------
  Future<void> _send(String text) async {
    if (_isUploadingAttachments || _isSending) return;

    _isSending = true;
    setState(() {});
    try {
      _forceSaveDraftDm();
      // 0) если висит staged forward — отправляем в этот чат
      if (_stagedForward != null && _forwardPackageAttached) {
        final forwardText = _stagedForward!.encodeForText();
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
                orElse: () => LocalAttach(path: '', name: '', mimeType: '', size: 0, isImage: false),
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
          }
        }

        final fileIds = collectedIds.toList();

        await widget.service.sendText(
          forwardText,
          replyToId: replyId,
          fileIds: fileIds.isEmpty ? null : fileIds,
        );

        _att.clear();
        _ctrl.clear();
        setState(() {
          _replyTo = null;
          _forwardPackageAttached = false;
          _stagedForward = null;
          _forwardSelectedIds.clear();
          _stagedForwardFileIds.clear();
        });
        FocusScope.of(context).unfocus();
        await _clearDraftDm();
        return;
      }

      // ---------- SAME-CHAT FORWARD (DM) ----------
      if (_forwardPackageAttached && _stagedForward == null) {
        final list = widget.service.currentMessages;
        final selected = list
            .where((m) => _forwardSelectedIds.contains(m.id))
            .toList()
          ..sort((a, b) => a.at.compareTo(b.at));

        if (selected.isEmpty) return;

        // собираем мета для FG и оригинальные file_id
        final items = <ForwardItem>[];
        final fileIds = <String>[];
        for (final m in selected) {
          final files = <ForwardFileRef>[];
          for (final f in (m.attachments ?? const <ChatFile>[])) {
            final url = (f.fileUrl ?? '');
            if (url.isNotEmpty) {
              files.add(ForwardFileRef(id: f.id, url: url, name: f.fileName, type: f.fileType, size: f.fileSize));
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
        final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
        final payload = ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

        final uniqueFileIds = fileIds.toSet().toList();
        await widget.service.sendText(
          payload.encodeForText(),
          replyToId: _replyTo?.id,
          fileIds: uniqueFileIds.isEmpty ? null : uniqueFileIds,
        );

        // очистка
        _att.pending.removeWhere((x) => x.path == '__FG__');
        _ctrl.clear();
        setState(() {
          _replyTo = null;
          _forwardPackageAttached = false;
          _forwardSelectedIds.clear();
        });
        FocusScope.of(context).unfocus();
        await _clearDraftDm();
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
              orElse: () => LocalAttach(path: '', name: '', mimeType: '', size: 0, isImage: false),
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('⏳ Файлы загружаются, подождите...')),
            );
          }
          return;
        }
        await widget.service.sendText(trimmed, replyToId: replyId, fileIds: fileIds);
        _att.clear();
      } else {
        await widget.service.sendText(trimmed, replyToId: replyId);
      }

      _ctrl.clear();
      setState(() => _replyTo = null);
      FocusScope.of(context).unfocus();
      await _clearDraftDm();
    } finally {
      _isSending = false;
      if (mounted) setState(() {});
    }
  }

  // ---------- Пересылка ----------
  Future<void> _handleForwardFlow() async {
    final list = widget.service.currentMessages;
    final selected = list.where((m) => _forwardSelectedIds.contains(m.id)).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
    if (selected.isEmpty) return;

    final items = <ForwardItem>[];
    final fileUrls = <String>[];
    final fileIds = <String>[];
    for (final m in selected) {
      final files = <ForwardFileRef>[];
      for (final f in (m.attachments ?? const <ChatFile>[])) {
        final url = (f.fileUrl ?? '');
        if (url.isNotEmpty) {
          files.add(ForwardFileRef(id: f.id, url: url, name: f.fileName, type: f.fileType, size: f.fileSize));
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
    final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
    final payload = ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

    final uniqueFileUrls = fileUrls.where((u) => u.isNotEmpty).toSet().toList();
    final uniqueFileIds = fileIds.where((id) => id.isNotEmpty).toSet().toList();

    final target = await pickForwardTarget(context);
    if (target == null) return;

    await ForwardOutbox.putForChat(
      chatId: target.chatId,
      text: payload.encodeForText(),
      fileUrls: uniqueFileUrls,
      fileIds: uniqueFileIds,
    );

    setState(() {
      _forwardPackageAttached = false;
      _stagedForward = null;
      _forwardSelectedIds.clear();
      _stagedForwardFileIds.clear();
      // Очищаем выбор после подготовки FG-пакета
      _selecting = false;
      _selectedIds.clear();
      _ctrl.clear();
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
        btnBox.localToGlobal(btnBox.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<String>(
      context: context,
      position: target,
      color: Theme.of(context).colorScheme.surface,
      shadowColor: Colors.black.withOpacity(0.25),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'search',
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search, size: 20, color: Colors.black),
              SizedBox(width: 10),
              Text('Поиск сообщений', style: TextStyle(color: Colors.black, fontSize: 16, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    );

    if (selected == 'search') {
      // ⚠️ фикс «первого нажатия»: принудительно перерисовываем экран
      setState(() { _search.setActive(true); });
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final titleText = widget.title ?? (widget.service.mode == ChatMode.dm ? 'Личный чат' : 'Чат');
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final theme = Theme.of(context);

    final isDm = widget.service.mode == ChatMode.dm;

    return Scaffold(
      appBar: AppBar(
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
                        builder: (_) => ChatMediaSheet(messagesStream: messages),
                      );
                    },
              )
            : Text(titleText, style: const TextStyle(color: Colors.black)),
        centerTitle: false,
        iconTheme: const IconThemeData(color: Colors.black),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Material(
              type: MaterialType.transparency,
              child: InkResponse(
                key: _kebabKey,
                radius: 22,
                onTap: _openKebabMenu,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.more_horiz, size: 24, color: Colors.black),
                ),
              ),
            ),
          ),
        ],
      ),
      body: StreamBuilder<List<Message>>(
        stream: widget.service.watchMessages(),
        initialData: widget.service.currentMessages,
        builder: (ctx, snap) {
          final list = snap.data ?? const <Message>[];

          if (_search.isActive) {
            _search.recompute(list, _isMatch);
          }

          if (list.isNotEmpty) {
            final newLastId = list.last.id;
            final changed = (newLastId != _lastRenderedLastId);
            _lastRenderedLastId = newLastId;
            if (changed && _chatScroll.atBottom()) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleSeenCheck());
            }
          }

          final pins = list
              .where((m) => m.isPinned)
              .map((m) => PinEntry.message(
                    id: m.id,
                    title: 'Сообщение',
                    subtitle: m.text.trim().isEmpty ? null : m.text.trim(),
                    messageId: m.id,
                  ))
              .toList();

          return Column(
            children: [
              if (_search.isActive)
                Theme(
                  data: theme.copyWith(
                    textTheme: theme.textTheme.apply(
                      bodyColor: Colors.black,
                      displayColor: Colors.black,
                    ),
                    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                      hintStyle: const TextStyle(color: Colors.black54),
                    ),
                  ),
                  child: InlineSearchBar(
                    controller: _search,
                    onClose: () => setState(() => _search.setActive(false)),
                  ),
                )
              else if (!_selecting && pins.isNotEmpty)
                PinnedStripContainer(
                  pins: pins,
                  controller: _pinsCtl,
                  onOpen: (p) { if (p.refId != null) _chatScroll.scrollToMessage(p.refId!); },
                  onUnpin: (p) async { if (p.type == PinType.message && p.refId != null) await widget.service.pinMessage(p.refId!, false); },
                ),

              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    if (_selecting) {
                      _selectedIds.clear();
                      setState(() => _selecting = false);
                    }
                  },
                  child: Stack(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(bottom: _selecting ? (safeBottom + 64 + 12) : 8.0),
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
                          onReply: (m) => setState(() => _replyTo = m),
                          onLongPress: (ctx, m, rect, bytes, replyPreview) =>
                              _showMessageActions(ctx, m, targetRect: rect, bubbleBytes: bytes, replyPreview: replyPreview),
                          onReplyTap: (id) => _chatScroll.scrollToMessage(id),
                          onReact: (ctx, id) => ca.ChatActions.showReactionPicker(ctx, (emoji) => widget.service.toggleReaction(id, emoji)),
                          selectingMessages: _selecting,
                          selectedMessageIds: _selectedIds,
                          onToggleSelect: (id) {
                            setState(() {
                              if (_selectedIds.contains(id)) _selectedIds.remove(id);
                              else _selectedIds.add(id);
                              if (_selectedIds.isEmpty) _selecting = false;
                            });
                          },
                          // В ЛС аватары не показываем принципиально
                          forceHideAvatars: widget.hideAvatars || isDm,
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),

                      if (_selecting)
                        Positioned(
                          top: 0, left: 0, right: 0,
                          child: TopSelectionBar(
                            count: _selectedIds.length,
                            onCancel: () { _selectedIds.clear(); setState(() => _selecting = false); },
                          ),
                        ),

                      if (_selecting)
                        Positioned(
                          left: 0, right: 0, bottom: 0,
                          child: BottomSelectionBar(
                            onForward: _selectedIds.isEmpty ? null : () async {
                              final sel = list.where((m) => _selectedIds.contains(m.id)).toList();
                              _selectedIds.clear();
                              setState(() => _selecting = false);
                              await _startForwardSelection(sel);
                            },
                            onDelete: (!_selectedIds.every((id) => _canDelete(list.firstWhere((m) => m.id == id))))
                                ? null
                                : () async {
                                    for (final id in _selectedIds.toList()) {
                                      await widget.service.deleteMessage(id);
                                    }
                                    _selectedIds.clear();
                                    setState(() => _selecting = false);
                                  },
                          ),
                        ),

                      if (_showJump)
                        Positioned(
                          right: 12,
                          bottom: _selecting ? (safeBottom + 64 + 20) : (safeBottom + 82.0),
                          child: ScrollToBottomButton(onTap: _jumpToBottom),
                        ),
                    ],
                  ),
                ),
              ),

              // Тонкая полоска статуса: идёт загрузка файлов или выполняется отправка
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: (_isUploadingAttachments || _isSending)
                    ? const LinearProgressIndicator(minHeight: 2)
                    : const SizedBox.shrink(),
              ),

              if (!_selecting)
                // ⚠️ ЛС и группы используют разные композеры
                (isDm)
                    ? DmComposerBar(
                        controller: _ctrl,
                        focusNode: _composerFocus,
                        replyTo: _replyTo,
                        onCloseReply: () => setState(() => _replyTo = null),
                        // DM: disable typing indicator
                        someoneTyping: false,
                        typingNames: const [],
                        attachedFiles: _att.pending.map((f) => AttachedFile(
                          path: f.path ?? '',
                          name: f.name ?? '',
                          isImage: f.isImage ?? false,
                          size: f.size ?? 0,
                        )).toList(),
                        isUploading: _isUploadingAttachments,
                        isSending: _isSending,
                        onAddFile: (ui) {
                          _att.add(LocalAttach(
                            path: ui.path, name: ui.name,
                            mimeType: ui.isImage ? 'image/jpeg' : 'application/octet-stream',
                            size: ui.size, isImage: ui.isImage,
                          ));
                          _saveDraftDmDebounced();
                        },
                        onRemoveFile: (ui) {
                          if (ui.path == '__FG__') {
                            setState(() {
                              _forwardPackageAttached = false;
                              _stagedForward = null;
                              _forwardSelectedIds.clear();
                              _stagedForwardFileIds.clear();
                              _att.pending.removeWhere((x) => x.path == '__FG__');
                            });
                          } else {
                            final local = _att.pending.firstWhere((f) => f.path == ui.path);
                            _att.remove(local);
                          }
                          _saveDraftDmDebounced();
                        },
                        onSend: () => _send(_ctrl.text),
                        onPickImage: () async {
                          final res = await ImagePicker().pickImage(source: ImageSource.gallery);
                          if (res != null) {
                            final file = LocalAttach(
                              path: res.path, name: res.path.split('/').last,
                              mimeType: 'image/jpeg', size: await File(res.path).length(), isImage: true,
                            );
                            _att.add(file);
                            final cid = await widget.service.ensureChatId();
                            _att.upload(file, teamId: null, chatId: cid);
                            _saveDraftDmDebounced();
                          }
                        },
                        onOpenEmoji: () {
                          _composerFocus.requestFocus();
                          services.SystemChannels.textInput.invokeMethod('TextInput.show');
                        },
                        onAttachFile: () async {
                          final file = await _fileService.pickFile();
                          if (file != null) {
                            final attached = LocalAttach(
                              path: file.path,
                              name: file.path.split('/').last,
                              mimeType: 'application/octet-stream',
                              size: await file.length(),
                              isImage: false,
                            );
                            _att.add(attached);
                            final cid = await widget.service.ensureChatId();
                            _att.upload(attached, teamId: null, chatId: cid);
                            _saveDraftDmDebounced();
                          }
                        },
                        onPinText: (text) => _pinsCtl.pinText(text),
                      )
                    : ChatComposerBar(
                        controller: _ctrl,
                        focusNode: _composerFocus,
                        replyTo: _replyTo,
                        onCloseReply: () => setState(() => _replyTo = null),
                        someoneTyping: _someoneTyping,
                        typingNames: _typingUsers.toList(),
                        attachedFiles: _att.pending.map((f) => AttachedFile(
                          path: f.path ?? '',
                          name: f.name ?? '',
                          isImage: f.isImage ?? false,
                          size: f.size ?? 0,
                        )).toList(),
                        isUploading: _isUploadingAttachments,
                        isSending: _isSending,
                        onAddFile: (ui) {
                          _att.add(LocalAttach(
                            path: ui.path, name: ui.name,
                            mimeType: ui.isImage ? 'image/jpeg' : 'application/octet-stream',
                            size: ui.size, isImage: ui.isImage,
                          ));
                        },
                        onRemoveFile: (ui) {
                          if (ui.path == '__FG__') {
                            setState(() {
                              _forwardPackageAttached = false;
                              _stagedForward = null;
                              _forwardSelectedIds.clear();
                              _stagedForwardFileIds.clear();
                              _att.pending.removeWhere((x) => x.path == '__FG__');
                            });
                          } else {
                            final local = _att.pending.firstWhere((f) => f.path == ui.path);
                            _att.remove(local);
                          }
                        },
                        onSend: () => _send(_ctrl.text),
                        onPickImage: () async {
                          final res = await ImagePicker().pickImage(source: ImageSource.gallery);
                          if (res != null) {
                            final file = LocalAttach(
                              path: res.path, name: res.path.split('/').last,
                              mimeType: 'image/jpeg', size: await File(res.path).length(), isImage: true,
                            );
                            _att.add(file);
                            final cid = await widget.service.ensureChatId();
                            _att.upload(file, teamId: null, chatId: cid);
                          }
                        },
                        onOpenEmoji: () => _composerFocus.requestFocus(),
                        onAttachFile: () async {
                          final file = await _fileService.pickFile();
                          if (file != null) {
                            final attached = LocalAttach(
                              path: file.path,
                              name: file.path.split('/').last,
                              mimeType: 'application/octet-stream',
                              size: await file.length(),
                              isImage: false,
                            );
                            _att.add(attached);
                            final cid = await widget.service.ensureChatId();
                            _att.upload(attached, teamId: null, chatId: cid);
                          }
                        },
                        onPinText: (text) => _pinsCtl.pinText(text),
                        onFind: () async {
                          FocusScope.of(context).unfocus();
                          _search.setActive(true);
                          setState((){}); // на всякий случай перерисовка
                        },
                        onPropose: (title, description, link, due, attachments) async {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                widget.service.supportsAssignments
                                    ? 'Задания подключим после бэка ЛС'
                                    : 'Задания недоступны в этом чате',
                              ),
                            ),
                          );
                        },
                      ),
            ],
          );
        },
      ),
    );
  }

  void _showMessageActions(BuildContext ctx, Message m, {Rect? targetRect, Uint8List? bubbleBytes, String? replyPreview}) async {
    setState(() => _hoveredMessageId = m.id);
    try {
      // Коррекция targetRect: используем прямоугольник ИМЕННО баббла в координатах Overlay
      Rect? finalRect = targetRect;
      if (finalRect == null) {
        final bubbleKey = _bubbleBoundaryKeys[m.id];
        if (bubbleKey?.currentContext != null) {
          final bubbleBox = bubbleKey!.currentContext!.findRenderObject() as RenderBox;
          final overlayBox = Overlay.of(ctx, rootOverlay: true).context.findRenderObject() as RenderBox;
          final topLeft = bubbleBox.localToGlobal(Offset.zero, ancestor: overlayBox);
          finalRect = topLeft & bubbleBox.size;
        }
      }

      await ca.ChatActions.showMessageActions(
        ctx,
        m,
        targetRect: finalRect,
        bubbleBytes: bubbleBytes,
        replyPreview: replyPreview,
        onReply: () => setState(() => _replyTo = m),
        onForward: () async { await _startForwardSelection([m]); },
        onTogglePin: () async => widget.service.pinMessage(m.id, !m.isPinned),
        onDeleteIfAllowed: () async => widget.service.deleteMessage(m.id),
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
    final ts = '${m.at.hour.toString().padLeft(2,'0')}:${m.at.minute.toString().padLeft(2,'0')}';
    if (ts.contains(q)) return true;
    final words = q.split(' ');
    if (words.length > 1) {
      final textLower = m.text.toLowerCase();
      final authorLower = m.authorName.toLowerCase();
      bool all = true;
      for (final w in words) {
        if (w.length > 2 && !textLower.contains(w) && !authorLower.contains(w)) {
          all = false; break;
        }
      }
      if (all) return true;
    }
    return false;
  }
}

class _DmTitle extends StatelessWidget {
  const _DmTitle({required this.title, this.avatarUrl, required this.onTap});
  final String title;
  final String? avatarUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Colors.black.withOpacity(.06),
            backgroundImage: (avatarUrl != null && avatarUrl!.isNotEmpty)
                ? CachedNetworkImageProvider(avatarUrl!) as ImageProvider
                : null,
            child: (avatarUrl == null || avatarUrl!.isEmpty)
                ? const Icon(Icons.person, size: 18, color: Colors.black)
                : null,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

