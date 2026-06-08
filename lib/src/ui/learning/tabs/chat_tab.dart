// ignore_for_file: unnecessary_import, unused_import, unused_field, unused_element, dead_null_aware_expression, invalid_null_aware_operator, unused_local_variable, deprecated_member_use, unnecessary_null_comparison

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:flutter/services.dart' as services;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';

import '../state/team_cubit.dart';
import '../models/message.dart';
import '../models/assignment.dart';
import '../models/chat_file.dart';
import '../models/local_attach.dart';
import '../assignment_details_screen.dart';
import '../../../services/file_service.dart';
import 'chat/data/chat_repository.dart';
import 'chat/actions/chat_actions.dart' as ca;
// ChatActions приходит через реэкспорт из widgets.dart
import '../global_cache.dart';
import '../../../services/image_cache_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
// Рефакторенные виджеты и контроллеры
import 'chat/widgets.dart';
import 'chat/search/inline_search_bar.dart';
import 'chat/assignments/edit_assignment_dialog.dart';
import 'chat/selection_bars.dart';
import '../../chats/core/forward_payload.dart';
import '../../chats/forward/forward_outbox.dart';
import '../../chats/forward/forward_picker.dart';
import '../../chats/forward/forward_pick_nav.dart';

class ChatTab extends StatefulWidget {
  final ValueChanged<bool>? onSelectingChanged;
  const ChatTab({super.key, this.onSelectingChanged});
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  final _ctrl = TextEditingController();
  late final ScrollController _scroll;
  final Map<String, Map<String, int>> _localReactions = {};
  final Map<String, GlobalKey> _messageKeys = {};
  final Map<String, GlobalKey> _bubbleBoundaryKeys = {};
  void _pruneBoundaryKeys(Set<String> aliveIds) {
    _bubbleBoundaryKeys.removeWhere((id, _) => !aliveIds.contains(id));
  }
  void _pruneMessageKeys(Set<String> aliveIds) {
    _messageKeys.removeWhere((id, _) => !aliveIds.contains(id));
  }

  // Контроллеры
  late final ChatScrollController _chatScroll;
  late final ChatSearchController _search;
  late final PinController _pinsCtl;
  late final ChatAttachmentsController _att;
  // Selection of messages
  bool _selectingMessages = false;
  final Set<String> _selectedMessageIds = {};
  bool _loadingOlderMessages = false;
  bool _hasMoreOlderMessages = true;
  // флаг и чип превью «пакет сообщений» в композере
  bool _forwardPackageAttached = false;
  final List<String> _forwardSelectedIds = [];
  final List<String> _stagedForwardFileIds = [];
  bool _canDeleteMessage(Message m) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty || m.authorId != uid) return false;
    return DateTime.now().difference(m.at) <= const Duration(hours: 12);
  }

  void _setSelecting(bool value) {
    if (_selectingMessages == value) {
      widget.onSelectingChanged?.call(value);
      return;
    }
    setState(() {
      _selectingMessages = value;
    });
    widget.onSelectingChanged?.call(value);
  }

  bool _showJump = false;
  Message? _replyTo;
  // Временная подсветка активного сообщения при открытом меню действий
  String? _actionsHoverId;


  final Set<String> _typingUsers = {};
  Timer? _myTypingOff;
  bool get _someoneTyping => _typingUsers.isNotEmpty;

  // Блокировка повторных отправок и индикатор фоновых загрузок
  bool _isSending = false;
  bool get _isUploadingAttachments =>
      _att.pending.any((f) => f.path != '__FG__' && (f.uploadedFileId == null));

  // Файлы в чате
  final FileService _fileService = FileService();
  late final ChatRepository _repo;
  // «граница на входе»: момент времени, до которого было прочитано при открытии
  DateTime? _entrySeenAt;
  // Показывать ли «Новые сообщения» в эту сессию (замораживаем на входе)
  bool _showEntryNewBadge = false;
  
  // Глобальный кэш
  final GlobalCache _globalCache = GlobalCache();
  final AppImageCache _imgCache = AppImageCache();
  final Set<String> _prefetchedImageUrls = {};
  String? _lastAutoScrollTarget;
  String? _lastMarkedReadId; // ➜ NEW: чтобы не спамить RPC
  Timer? _seenDebounce; // ➜ NEW: debounce для автопрочтения
  String? _lastRenderedLastId; // ➜ NEW: отслеживаем последний id в ленте
  ForwardPayload? _stagedForward; // пакет для пересылки из других чатов

  // Функция поиска сообщений - используется в ChatSearchController
  bool _isMessageMatched(Message m, String query) {
    if (query.isEmpty) return false;
    final q = query.toLowerCase().trim();
    
    // Поиск по тексту сообщения (основной)
    if (m.text.toLowerCase().contains(q)) return true;
    
    // Поиск по имени автора
    if (m.authorName.toLowerCase().contains(q)) return true;
    if (m.authorLogin.toLowerCase().contains(q)) return true;
    
    // Поиск по вложениям
    final atts = m.attachments ?? const <ChatFile>[];
    for (final f in atts) {
      if (f.fileName.toLowerCase().contains(q)) return true;
      // Поиск по расширению файла
      final ext = f.fileName.split('.').last.toLowerCase();
      if (ext.contains(q)) return true;
    }
    
    // Поиск по времени (часы:минуты)
    final timeStr = '${m.at.hour.toString().padLeft(2,'0')}:${m.at.minute.toString().padLeft(2,'0')}';
    if (timeStr.contains(q)) return true;
    
    // Поиск по дате (если введена дата)
    if (q.contains(':') && q.length <= 5) {
      // Это похоже на время
      final timeParts = q.split(':');
      if (timeParts.length == 2) {
        final hour = timeParts[0];
        final minute = timeParts[1];
        if (m.at.hour.toString().padLeft(2, '0') == hour && 
            m.at.minute.toString().padLeft(2, '0') == minute) {
          return true;
        }
      }
    }
    
    // Поиск по частичному совпадению слов
    final words = q.split(' ');
    if (words.length > 1) {
      final textLower = m.text.toLowerCase();
      final authorLower = m.authorName.toLowerCase();
      
      // Проверяем, содержатся ли все слова в тексте или авторе
      bool allWordsFound = true;
      for (final word in words) {
        if (word.length > 2 && // игнорируем короткие слова
            !textLower.contains(word) && 
            !authorLower.contains(word)) {
          allWordsFound = false;
          break;
        }
      }
      if (allWordsFound) return true;
    }
    
    return false;
  }
  // removed: legacy file cache fetch; composer picked image not used

  final FocusNode _composerFocus = FocusNode();
  
  // ID текущего чата для черновиков
  String? _currentChatId;

  // removed: assignment scale/text boost constants

  static const services.MethodChannel _keyboardChannel =
      services.MethodChannel('keyboard_image_channel');

  // Инициализация границы «видел до» на входе
  Future<void> _initEntryBoundary() async {
    try {
      final teamId = context.read<TeamCubit>().state.team.id;
      final chatId = await _getChatIdForTeam(teamId);
      final seenAtRaw = await _repo.getLastSeenAt(chatId: chatId);
      DateTime? entry = seenAtRaw?.toUtc();

      if (entry == null) {
        try {
          final unread = await _repo.getUnreadInChat(chatId);
          final firstId = unread['first_unread_id'] as String?;
          if (firstId != null && firstId.isNotEmpty) {
            final listNow = context.read<TeamCubit>().state.chat;
            final idx = listNow.indexWhere((m) => m.id == firstId);
            if (idx != -1) {
              final t = listNow[idx].at.toUtc();
              entry = t.subtract(const Duration(microseconds: 1));
            }
          }
        } catch (_) {}
      }

      // ВАЖНО: границу всегда сохраняем, а флаг показываемости фиксируем отдельно
      bool showBadge = false;
      if (entry != null) {
        try {
          final unread = await _repo.getUnreadInChat(chatId);
          final String? firstId = unread['first_unread_id'] as String?;
          final int unreadCount = (unread['unread_count'] ?? unread['count'] ?? 0) as int;
          showBadge = (firstId != null && firstId.isNotEmpty) || unreadCount > 0;
        } catch (_) {
          final listNow = context.read<TeamCubit>().state.chat;
          showBadge = listNow.any((m) => m.at.toUtc().isAfter(entry!));
        }
      }
      if (!mounted) return;
      setState(() {
        _entrySeenAt = entry;          // freeze boundary на всю сессию
        _showEntryNewBadge = showBadge; // freeze показываемость на момент входа
      });
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    _scroll.addListener(_onScroll);
    _ctrl.addListener(_onMyTyping);
    
    // Инициализируем контроллеры
    _chatScroll = ChatScrollController(_scroll, _messageKeys);
    _search = ChatSearchController();
    _pinsCtl = PinController();
    _att = ChatAttachmentsController(_fileService, _globalCache, Supabase.instance.client)
      ..addListener(() { if (mounted) setState(() {}); });
    _repo = ChatRepository(supabase: Supabase.instance.client, fileService: _fileService);
    
    // Добавляем слушатель для поля поиска
    _search.field.addListener(() {
      if (mounted) {
        _search.recompute(context.read<TeamCubit>().state.chat, _isMessageMatched);
      }
    });

    // Автопрокрутка при смене текущей цели поиска
    _search.addListener(() async {
      if (!mounted) return;
      final id = _search.currentTargetId;
      if (_search.isActive && id.isNotEmpty && id != _lastAutoScrollTarget) {
        _lastAutoScrollTarget = id;
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMessage(id));
      }
    });
    
    // Добавляем слушатель потери фокуса для сохранения черновика
    _composerFocus.addListener(() {
      if (!_composerFocus.hasFocus) {
        _forceSaveDraft();
      }
    });
    
    // Загружаем файлы для старых сообщений
    _loadOldFiles();
    
    // Показываем статистику кэша
    _globalCache.showCacheStats();
    
    // Подписываемся на изменения чата
    // context.read<TeamCubit>().stream.listen((state) {
    //   if (mounted) {
    //     setState(() {
    //       _messages = state.chat;
    //     });
    //   }
    // });

    _keyboardChannel.setMethodCallHandler((call) async {
      if (call.method == 'onKeyboardImagePicked' || call.method == 'onPicked') {
        final path = (call.arguments ?? '') as String;
        if (path.isNotEmpty && mounted) {
          // Добавляем файл в pending список
          final file = LocalAttach(
            path: path,
            name: path.split('/').last,
            mimeType: 'image/jpeg',
            size: await File(path).length(),
            isImage: true,
          );
          _att.add(file);
          final teamId = context.read<TeamCubit>().state.team.id;
          final chatId = await _getChatIdForTeam(teamId);
          // ignore: unawaited_futures
          _att.upload(file, teamId: teamId, chatId: chatId);
        }
      }
      return null;
    });

    // Устанавливаем ID чата и восстанавливаем черновик
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Получаем ID чата из TeamCubit
      final teamId = context.read<TeamCubit>().state.team.id;
      _currentChatId = teamId;
      _restoreDraft();
      () async {
        final chatId = await _getChatIdForTeam(teamId);
        await _consumeForwardOutboxIfAny(chatId);
      }();

      // Асинхронно фиксируем «границу на входе» по last_read_at / first_unread_id
      _initEntryBoundary();

      // Prefetch изображений для текущей ленты
      final imgs = context.read<TeamCubit>().state.chat
          .expand((m) => (m.attachments ?? const []))
          .where((f) => f.isImage)
          .map<String>((f) => f.fileUrl);
      _imgCache.prefetchUrls(imgs);
      
      // Плавно скроллим вниз после инициализации
      _jumpToBottom();
      // ➜ NEW: если сразу внизу — отметить прочитанным
      final list = context.read<TeamCubit>().state.chat;
      if (list.isNotEmpty && _chatScroll.atBottom()) {
        _markReadSafely(list.last.id);
      }
    });
  }

  @override
  void dispose() {
    // ➜ NEW: финальная подстраховка
    try {
      final list = context.read<TeamCubit>().state.chat;
      if (list.isNotEmpty) _markReadSafely(list.last.id);
    } catch (_) {}
    // Принудительно сохраняем черновик перед уничтожением
    _forceSaveDraft();
    
    // Попробуем гарантированно скрыть системную клавиатуру
    try {
      FocusManager.instance.primaryFocus?.unfocus();
      services.SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
    // И попросим нативный слой убрать captureView, если он использовался
    try { _keyboardChannel.invokeMethod('dispose'); } catch (_) {}

    _seenDebounce?.cancel();
    _scroll.removeListener(_onScroll);
    _ctrl.removeListener(_onMyTyping);
    _scroll.dispose();
    _ctrl.dispose();
    _composerFocus.dispose();
    _myTypingOff?.cancel();
    _draftSaveTimer?.cancel();
    
    // Уничтожаем контроллеры
    _keyboardChannel.setMethodCallHandler(null);
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    final show = !_chatScroll.atBottom();
    if (show != _showJump) {
      _showJump = show;
      if (mounted) setState(() {});
    }

    if (_isNearHistoryTop()) {
      _loadOlderMessages();
    }

    // ➜ NEW: если внизу ленты — помечаем чат прочитанным до последнего сообщения
    if (_chatScroll.atBottom()) {
      final list = context.read<TeamCubit>().state.chat;
      if (list.isNotEmpty) {
        final last = list.last;
        if (last.id != _lastMarkedReadId) {
          _markReadSafely(last.id);
        }
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
    _loadingOlderMessages = true;
    if (mounted) setState(() {});

    try {
      final loaded = await context.read<TeamCubit>().loadOlderMessages(limit: 50);
      if (loaded.length < 50) {
        _hasMoreOlderMessages = false;
      }
    } finally {
      _loadingOlderMessages = false;
      if (mounted) setState(() {});
    }
  }

  // ➜ NEW: помощник для вызова RPC mark_read
  Future<void> _markReadSafely(String lastMsgId) async {
    try {
      final teamId = context.read<TeamCubit>().state.team.id;
      final chatId = await _getChatIdForTeam(teamId);
      if (chatId.isEmpty) return; // ← NEW safeguard
      await _repo.markRead(chatId: chatId, messageId: lastMsgId);
      _lastMarkedReadId = lastMsgId;
    } catch (e) {
      if (kDebugMode) debugPrint('[ChatTab] markRead error: $e');
    }
  }

  void _onMyTyping() {
    // Обновляем typing без setState для избежания лишних обновлений
    _typingUsers.add('Вы');
    _myTypingOff?.cancel();
    _myTypingOff = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      _typingUsers.remove('Вы');
    });
    
    // Сохраняем черновик при изменении текста (с задержкой для избежания частых сохранений)
    _saveDraftDebounced();
  }
  
  Timer? _draftSaveTimer;
  void _saveDraftDebounced() {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 300), () {
      _saveDraft();
    });
  }
  
  // Принудительно сохраняем черновик перед выходом
  void _forceSaveDraft() {
    _draftSaveTimer?.cancel();
    _saveDraft();
  }

  // removed: time helpers and key helpers moved to extracted widgets

  Future<void> _jumpToBottom() async {
    await _chatScroll.jumpToBottom();
  }

  // ➜ NEW: debounce + проверка «видим ли нижний край», затем отметить прочитанным
  void _scheduleSeenCheck() {
    _seenDebounce?.cancel();
    _seenDebounce = Timer(const Duration(milliseconds: 150), _markLastSeenIfNeeded);
  }

  Future<void> _markLastSeenIfNeeded() async {
    if (!mounted) return;
    if (!_chatScroll.atBottom()) return;
    final list = context.read<TeamCubit>().state.chat;
    if (list.isEmpty) return;
    final last = list.last;
    if (last.id == _lastMarkedReadId) return;
    await _markReadSafely(last.id);
  }

  Future<void> _scrollToMessage(String id) async {
    await _chatScroll.scrollToMessage(id);
  }



  // Функция добавления реакции - используется в ChatActions
  Future<void> _addReaction(String msgId, String emoji) async {
    // call RPC to toggle reaction; repository will update DB and realtime will sync
    try {
      debugPrint('[ChatTab] toggleReaction RPC calling for $msgId $emoji');
      final res = await _repo.toggleReaction(msgId, emoji);
      debugPrint('[ChatTab] toggleReaction RPC completed for $msgId $emoji -> $res');
    } catch (e, st) {
      debugPrint('[ChatTab] toggleReaction ERROR: $e');
      debugPrint('$st');
    }
  }
  
  // Сохраняем черновик в глобальный кэш
  Future<void> _saveDraft() async {
    if (_currentChatId != null) {
      final filesData = _att.pending.map((f) => {
        'path': f.path ?? '',
        'name': f.name ?? '',
        'mimeType': f.mimeType ?? '',
        'size': f.size ?? 0,
        'isImage': f.isImage ?? false,
        'uploadedFileId': f.uploadedFileId,
      }).toList();
      
      await _globalCache.saveDraft(_currentChatId!, _ctrl.text, filesData);
      print('💾 Черновик сохранен для чата $_currentChatId: текст="${_ctrl.text}", файлов=${filesData.length}');
    }
  }
  
  // Восстанавливаем черновик из глобального кэша
  void _restoreDraft() {
    if (_currentChatId != null) {
      final draft = _globalCache.getDraft(_currentChatId!);
      if (draft != null) {
        final (text, filesData) = draft;
        _ctrl.text = text;
        _att.pending.clear();
        
        for (final fileData in filesData) {
          _att.pending.add(LocalAttach(
            path: fileData['path'] as String? ?? '',
            name: fileData['name'] as String? ?? '',
            mimeType: fileData['mimeType'] as String? ?? '',
            size: fileData['size'] as int? ?? 0,
            isImage: fileData['isImage'] as bool? ?? false,
            uploadedFileId: fileData['uploadedFileId'] as String?,
          ));
        }
        
        print('📝 Черновик загружен для чата $_currentChatId: текст="$text", файлов=${filesData.length}');
        
        if (mounted) {
          setState(() {}); // Обновляем UI для отображения восстановленных файлов
        }
      }
    }
  }
  
  // Очищаем черновик
  Future<void> _clearDraft() async {
    if (_currentChatId != null) {
      await _globalCache.clearDraft(_currentChatId!);
    }
  }

  void _send(BuildContext context) async {
    // защита от повторных тапов и отправки во время аплоада
    if (_isUploadingAttachments || _isSending) return;

    _isSending = true;
    setState(() {});
    try {
      // если это пакет из другого чата (есть _stagedForward)
      if (_stagedForward != null && _forwardPackageAttached) {
        final teamId = context.read<TeamCubit>().state.team.id;
        final forwardText = _stagedForward!.encodeForText();

        // ждём загрузки всех реальных pending-файлов (кроме '__FG__')
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

        await _repo.sendMessageWithFiles(teamId, forwardText, fileIds);
        setState(() {
          _forwardPackageAttached = false;
          _stagedForward = null;
          _forwardSelectedIds.clear();
          _stagedForwardFileIds.clear();
          _att.clear();
          _ctrl.clear();
        });
        return;
      }
      // same-chat forward: как в ЛС — обычный ForwardPayload + encodeForText()
      if (_forwardPackageAttached && _stagedForward == null) {
        final teamId = context.read<TeamCubit>().state.team.id;
        final all = context.read<TeamCubit>().state.chat;
        final selected = all
            .where((m) => _forwardSelectedIds.contains(m.id))
            .toList()
          ..sort((a, b) => a.at.compareTo(b.at));

        if (selected.isEmpty) return;

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
            text: (m.text ?? '').trim(),
            files: files,
          ));
        }

        final fromChatId = await _getChatIdForTeam(teamId);
        final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
        final payload = ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

        final uniqueFileIds = fileIds.toSet().toList();
        await _repo.sendMessageWithFiles(
          teamId,
          payload.encodeForText(),
          uniqueFileIds,
        );

        setState(() {
          _forwardPackageAttached = false;
          _forwardSelectedIds.clear();
          _stagedForwardFileIds.clear();
          _att.pending.removeWhere((x) => x.path == '__FG__');
          _ctrl.clear();
          _replyTo = null;
        });
        FocusScope.of(context).unfocus();
        await _clearDraft();
        return;
      }

      final text = _ctrl.text.trim();
      if (text.isEmpty && _att.pending.isEmpty) return;

      // Принудительно сохраняем черновик перед отправкой
      _forceSaveDraft();

      final replyId = _replyTo?.id;
      final filesToSend = _att.getPendingFiles(); // Копируем список файлов

      // Если есть прикрепленные файлы, отправляем их вместе с текстом
      if (filesToSend.isNotEmpty) {
        final ok = await _sendMessageWithFiles(text, replyId, filesToSend);
        if (!ok) return; // Ждём загрузку файлов, не чистим поля
      } else {
        // Только текст
        context.read<TeamCubit>().sendMessage(
          'me',
          text,
          replyToId: replyId,
        );
      }

      _ctrl.clear();
      _replyTo = null;

      // Очищаем черновик после отправки
      _clearDraft();
      
      // Скрываем клавиатуру после отправки
      FocusScope.of(context).unfocus();
    } finally {
      _isSending = false;
      if (mounted) setState(() {});
    }
  }

  Future<bool> _sendMessageWithFiles(String text, String? replyId, List<LocalAttach> filesToSend) async {
    try {
      // Дожидаемся загрузки файлов (uploadedFileId) максимум 8 секунд
      final paths = filesToSend.map((f) => f.path).toList();
      const maxTries = 40; // 40 * 200мс = 8с
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⏳ Файлы загружаются, подождите...')),
        );
        return false;
      }

      // Вызываем новую RPC для отправки сообщения с файлами
      final messageId = await _repo.sendMessageWithFiles(context.read<TeamCubit>().state.team.id, text, fileIds);

      // Очищаем список прикрепленных файлов
      _att.clear();

      return true;
    } catch (e) {
      print('❌ Ошибка отправки сообщения с файлами: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Ошибка отправки: $e'),
          backgroundColor: Colors.red,
        ),
      );
      return false;
    }
  }

  // Новая RPC функция для отправки сообщения с файлами
  // removed: _sendMessageWithFilesRPC moved to ChatRepository

  // removed: unused pluralization helper



  Future<void> _uploadFileToChat(File file, [String? messageId]) async {
    try {
      // Получаем текущего пользователя
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Не удалось получить пользователя')),
        );
        return;
      }

      // Получаем chatId для команды
      final teamId = context.read<TeamCubit>().state.team.id;
      final chatId = await _getChatIdForTeam(teamId);

      // Создаем метаданные файла
      final chatFile = ChatFile(
        id: '',
        chatId: chatId,
        messageId: messageId, // Используем переданный messageId
        fileName: file.path.split('/').last,
        fileKey: '',
        fileUrl: '',
        fileType: 'application/octet-stream',
        fileSize: await file.length(),
        uploadedBy: user.id,
        uploadedAt: DateTime.now(),
      );

      // Сохраняем файл в БД и получаем его ID
      final savedChatFile = await _saveChatFileToDatabase(chatFile, user.id);
      
      // Загружаем файл в Yandex Storage
      final uploadResult = await _fileService.uploadFileToChat(
        file: file,
        chatId: chatId,
        messageId: messageId ?? '', // Используем переданный messageId
        uploadedBy: user.id,
      );

      // Обновляем chat_file с результатами загрузки
      await Supabase.instance.client
          .from('chat_files')
          .update({
            'file_key': uploadResult.fileKey,
            'file_url': uploadResult.fileUrl,
            'file_type': uploadResult.fileType,
            'file_size': uploadResult.fileSize,
          })
          .eq('id', savedChatFile.id);
      
      print('✅ Файл обновлен в БД: ${uploadResult.fileName}');
      print('📁 URL в БД: ${uploadResult.fileUrl}');

      // Если messageId не передан, создаем сообщение с файлом через репозиторий
      if (messageId == null) {
        final newMessageId = await _repo.sendMessageWithFiles(
          teamId,
          '📎 ${uploadResult.fileName}',
          [savedChatFile.id],
        );
        print('📝 Создано сообщение с файлом через RPC: messageId=$newMessageId');
      }

      // Файлы теперь загружаются автоматически через attachments в Message
      print('✅ Файл загружен: ${uploadResult.fileName}');
      print('📁 URL: ${uploadResult.fileUrl}');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Файл "${uploadResult.fileName}" загружен!'),
          backgroundColor: Colors.green,
        ),
      );

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Ошибка загрузки: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showFileUploadSheet(BuildContext context) {
    // Простое меню выбора файла
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('Выбрать файл'),
              onTap: () async {
                Navigator.pop(context);
                final file = await _fileService.pickFile();
                if (file != null) {
                  await _uploadFileToChat(file);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Выбрать изображение'),
              onTap: () async {
                Navigator.pop(context);
                final file = await _fileService.pickImage();
                if (file != null) {
                  await _uploadFileToChat(file);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // removed: message list builder moved to ChatMessageList

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final scale = mq.textScaleFactor.clamp(1.0, 1.2);
    final themed = Theme.of(context);

    const listBottomPad = 96.0;

    return MediaQuery(
      data: mq.copyWith(textScaleFactor: scale),
      child: BlocBuilder<TeamCubit, TeamState>(
        buildWhen: (previous, current) {
          // Обновляем только если изменился чат или команда
          return previous.chat != current.chat || 
                 previous.team != current.team ||
                 previous.assignments != current.assignments;
        },
        builder: (context, state) {
          final safeBottom = MediaQuery.of(context).padding.bottom;
          const bottomActionsContent = 64.0; // кнопки ~44 + вертикальные паддинги
          final listPadBottom = _selectingMessages
              ? safeBottom + bottomActionsContent + 12
              : 8.0;
          final jumpBottom = _selectingMessages
              ? (safeBottom + bottomActionsContent + 20)
              : (safeBottom + 82.0);
          final list = state.chat;
          final pins = _pinsCtl.buildFromState(state);
          // prune keys to avoid leaks
          _pruneMessageKeys(list.map((m) => m.id).toSet());
          _pruneBoundaryKeys(list.map((m) => m.id).toSet());

          // Обновляем поиск при изменении чата
          if (_search.isActive) {
            _search.recompute(list, _isMessageMatched);
          }

          // ➜ NEW: если пришёл новый последний id и мы держим низ — отметить прочитанным
          if (list.isNotEmpty) {
            final newLastId = list.last.id;
            final changed = (newLastId != _lastRenderedLastId);
            _lastRenderedLastId = newLastId;
            if (changed && _chatScroll.atBottom()) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _scheduleSeenCheck();
              });
            }
          }

          // initialScrollOffset уже сдвигает в конец, доп.скролл не нужен

          return Column(
            children: [
              if (_search.isActive)
                InlineSearchBar(
                  controller: _search,
                  onClose: () => _search.setActive(false),
                )
              else if (!_selectingMessages && !_pinsCtl.hidden && pins.isNotEmpty)
                PinnedStripContainer(
                  pins: pins,
                  controller: _pinsCtl,
                  onOpen: _onOpen,
                  onUnpin: (p) async {
                    if (p.type == PinType.message && p.refId != null) {
                      await context.read<TeamCubit>().pinMessage(p.refId!, false);
                    }
                  },
                ),

              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    _forceSaveDraft();
                    if (_selectingMessages) {
                      _selectedMessageIds.clear();
                      _setSelecting(false);
                    }
                  },
                  child: Stack(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(bottom: listPadBottom),
                        child: ChatMessageList(
                          messages: state.chat,
                          controller: _scroll,
                          messageKeys: _messageKeys,
                          boundaryKeys: _bubbleBoundaryKeys,
                          search: _search,
                          currentUserId: Supabase.instance.client.auth.currentUser?.id,
                          entrySeenAt: _entrySeenAt,
                          showEntryNewBadge: _showEntryNewBadge,
                          hoveredMessageId: _actionsHoverId,
                          onReply: (m) { setState(() => _replyTo = m); },
                          onLongPress: (ctx, m, rect, bytes, replyPreview) => _showMessageActions(ctx, m, targetRect: rect, bubbleBytes: bytes, replyPreview: replyPreview),
                          onReplyTap: (id) => _scrollToMessage(id),
                          onReact: (ctx, id) => ca.ChatActions.showReactionPicker(ctx, (emoji) => _addReaction(id, emoji)),
                          selectingMessages: _selectingMessages,
                          selectedMessageIds: _selectedMessageIds,
                          onToggleSelect: (id) {
                            setState(() {
                              if (_selectedMessageIds.contains(id)) {
                                _selectedMessageIds.remove(id);
                                if (_selectedMessageIds.isEmpty) {
                                  // defer flag change outside setState to notify
                                }
                              } else {
                                _selectedMessageIds.add(id);
                              }
                            });
                            if (_selectedMessageIds.isEmpty && _selectingMessages) {
                              _setSelecting(false);
                            }
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
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                      // внутренние действия бабла уже выключены в списке; отдельный overlay не нужен

                      // Верхняя панель выбора (полноширинная)
                      if (_selectingMessages)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: TopSelectionBar(
                            count: _selectedMessageIds.length,
                            onCancel: () { _selectedMessageIds.clear(); _setSelecting(false); },
                          ),
                        ),

                      // Нижняя панель действий (переслать / удалить) в самом низу
                      if (_selectingMessages)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Builder(builder: (ctx2) {
                            final selected = state.chat.where((m) => _selectedMessageIds.contains(m.id)).toList();
                            final canDeleteAll = selected.isNotEmpty && selected.every(_canDeleteMessage);
                            return BottomSelectionBar(
                              onForward: _selectedMessageIds.isEmpty ? null : () async {
                                final sel = state.chat
                                    .where((m) => _selectedMessageIds.contains(m.id))
                                    .toList()
                                  ..sort((a, b) => a.at.compareTo(b.at));
                                _selectedMessageIds.clear();
                                _setSelecting(false);
                                await _startForwardSelection(sel);
                              },
                              onDelete: (!canDeleteAll)
                                  ? null
                                  : () async {
                                      for (final id in _selectedMessageIds.toList()) {
                                        await context.read<TeamCubit>().removeMessage(id);
                                      }
                                      _selectedMessageIds.clear();
                                      _setSelecting(false);
                                    },
                            );
                          }),
                        ),

                      if (_showJump)
                        Positioned(
                          right: 12,
                          bottom: jumpBottom,
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

              if (!_selectingMessages)
                ChatComposerBar(
                  controller: _ctrl,
                  focusNode: _composerFocus,
                  replyTo: _replyTo,
                  onCloseReply: () { setState(() => _replyTo = null); },
                  someoneTyping: _someoneTyping,
                  typingNames: _typingUsers.toList(),
                  attachedFiles: _att.pending.map((f) {
                    return AttachedFile(
                      path: f.path ?? '',
                      name: f.name ?? '',
                      isImage: f.isImage ?? false,
                      size: f.size ?? 0,
                    );
                  }).toList(),
                  isUploading: _isUploadingAttachments,
                  isSending: _isSending,
                  onSend: () => _send(context),
                  onAddFile: (ui) {
                    _att.add(LocalAttach(
                      path: ui.path,
                      name: ui.name,
                      mimeType: ui.isImage ? 'image/jpeg' : 'application/octet-stream',
                      size: ui.size,
                      isImage: ui.isImage,
                    ));
                  },
                  onRemoveFile: (ui) {
                    if (ui.path == '__FG__') {
                      setState(() {
                        _forwardPackageAttached = false;
                        _stagedForward = null;
                        _forwardSelectedIds.clear();
                        _att.pending.removeWhere((x) => x.path == '__FG__');
                      });
                    } else {
                      final local = _att.pending.firstWhere((f) => f.path == ui.path);
                      _att.remove(local);
                    }
                  },
                  onPickImage: () async {
                    final res = await ImagePicker().pickImage(source: ImageSource.gallery);
                    if (res != null) {
                      final file = LocalAttach(
                        path: res.path,
                        name: res.path.split('/').last,
                        mimeType: 'image/jpeg',
                        size: await File(res.path).length(),
                        isImage: true,
                      );
                      _att.add(file);
                      final teamId = context.read<TeamCubit>().state.team.id;
                      final chatId = await _getChatIdForTeam(teamId);
                      // ignore: unawaited_futures
                      _att.upload(file, teamId: teamId, chatId: chatId);
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
                      final teamId = context.read<TeamCubit>().state.team.id;
                      final chatId = await _getChatIdForTeam(teamId);
                      // ignore: unawaited_futures
                      _att.upload(attached, teamId: teamId, chatId: chatId);
                    }
                  },
                  onPinText: (text) => _pinsCtl.pinText(text),
                  onFind: () async {
                    // Показать ТОЛЬКО верхнюю строку поиска, без нижнего листа
                    FocusScope.of(context).unfocus();
                    _search.setActive(true);
                  },
                  onPropose: (title, description, link, due, attachments) async {
                    await context.read<TeamCubit>().proposeAssignment(
                      title: title, description: description, link: link, due: due, attachments: attachments,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  // Функция показа действий с сообщением - используется в ChatActions
  void _showMessageActions(BuildContext context, Message m, {Rect? targetRect, Uint8List? bubbleBytes, String? replyPreview}) async {
    // включаем временную подсветку «как будто выделено»
    setState(() => _actionsHoverId = m.id);

    // If the popup won't fit below the message, nudge the list up slightly so it fits.
    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    final safeBottom = media.padding.bottom + 8;
    const panelDesiredHeight = 160.0; // emoji pill + actions approx

    Rect? finalRect = targetRect;

    if (targetRect != null) {
      final availableBelow = screenH - targetRect.bottom - safeBottom;
      if (availableBelow < panelDesiredHeight) {
        final need = (panelDesiredHeight - availableBelow) + 8.0;
        final maxScroll = _scroll.position.maxScrollExtent;
        final to = (_scroll.offset + need).clamp(0.0, maxScroll);
        try {
          await _scroll.animateTo(to, duration: const Duration(milliseconds: 220), curve: Curves.easeInOut);
        } catch (_) {}

        // recompute rect from BUBBLE boundary key after scroll, in Overlay coordinates
        final bubbleKey = _bubbleBoundaryKeys[m.id];
        if (bubbleKey?.currentContext != null) {
          final bubbleBox = bubbleKey!.currentContext!.findRenderObject() as RenderBox;
          final overlayBox = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox;
          final topLeft = bubbleBox.localToGlobal(Offset.zero, ancestor: overlayBox);
          finalRect = topLeft & bubbleBox.size;
        }
      }
    }
    // If we weren't given a targetRect (or after scroll without need), compute from bubble key now as well
    if (finalRect == null) {
      final bubbleKey = _bubbleBoundaryKeys[m.id];
      if (bubbleKey?.currentContext != null) {
        final bubbleBox = bubbleKey!.currentContext!.findRenderObject() as RenderBox;
        final overlayBox = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox;
        final topLeft = bubbleBox.localToGlobal(Offset.zero, ancestor: overlayBox);
        finalRect = topLeft & bubbleBox.size;
      }
    }

    try {
      await ca.ChatActions.showMessageActions(
        context,
        m,
        targetRect: finalRect,
        bubbleBytes: null,
        replyPreview: replyPreview,
        onReply: () {
          _replyTo = m;
          setState(() {});
        },
        onForward: () async {
          await _startForwardSelection(<Message>[m]);
        },
        onTogglePin: () => context.read<TeamCubit>().pinMessage(m.id, !m.isPinned),
        onDeleteIfAllowed: () => context.read<TeamCubit>().removeMessage(m.id),
        onReact: (emoji) => _addReaction(m.id, emoji),
        onSelect: () {
          _selectedMessageIds.add(m.id);
          _setSelecting(true);
        },
      );
    } finally {
      if (mounted) setState(() => _actionsHoverId = null);
    }
  }

  // removed: assignment actions handled in ChatActions and UI components

  // removed: inline edit assignment dialog (moved to showEditAssignmentDialog)





  // Скачиваем файл
  Future<void> _downloadFile(ChatFile file) async {
    final result = await _repo.downloadFile(file);
    if (result.success && result.file != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Файл "${file.fileName}" скачан'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Ошибка скачивания: ${result.error}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // Получаем chatId для команды
  Future<String> _getChatIdForTeam(String teamId) => _repo.getMainChatId(teamId);

  Future<void> _consumeForwardOutboxIfAny(String chatId) async {
    final data = await ForwardOutbox.tryTakeForChat(chatId);
    if (data == null) return;
    final raw = data.text ?? '';
    if (!ForwardPayload.isForwardText(raw)) {
      if (raw.isNotEmpty) {
        _ctrl.text = raw;
        _ctrl.selection = TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
      }
      return;
    }
    final payload = ForwardPayload.tryParse(raw);
    if (payload == null) return;
    await _stageForwardPayload(payload, data.fileUrls, chatId);
  }

  Future<void> _stageForwardPayload(ForwardPayload payload, List<String> fileUrls, String chatId) async {
    if (!mounted) return;
    final sameChat = payload.fromChatId == chatId;

    if (!_att.pending.any((x) => x.path == '__FG__')) {
      _att.pending.add(LocalAttach(
        path: '__FG__',
        name: 'forward.json',
        mimeType: 'application/json',
        size: 0,
        isImage: false,
      ));
    }

    if ((payload.caption ?? '').isNotEmpty) {
      _ctrl.text = payload.caption!;
      _ctrl.selection = TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
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
      });
      return;
    }

    setState(() {
      _forwardPackageAttached = true;
      _stagedForward = payload;
      _forwardSelectedIds.clear();
    });

    final uniqueUrls = fileUrls.where((u) => u.isNotEmpty).toSet();
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
        _att.upload(attach, teamId: context.read<TeamCubit>().state.team.id, chatId: chatId);
      } catch (e) {
        if (kDebugMode) debugPrint('[ChatTab] stageForward error: $e');
      }
    }
  }

  // вспомогательное — как в UnifiedChatScreen
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

  Future<void> _startForwardSelection(List<Message> selected) async {
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
        text: (m.text ?? '').trim(),
        files: files,
      ));
    }

    final teamId = context.read<TeamCubit>().state.team.id;
    final fromChatId = await _getChatIdForTeam(teamId);
    final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
    final payload = ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

    final uniqueFileUrls = fileUrls.where((u) => u.isNotEmpty).toSet().toList();
    final uniqueFileIds = fileIds.where((id) => id.isNotEmpty).toSet().toList();

    final target = await pickForwardTarget(context);
    if (target == null) return;

    if (target.chatId == fromChatId) {
      // Без staged чипов и перезакачек — просто вставим FG в композер
      _ctrl.text = payload.encodeForText();
      _ctrl.selection = TextSelection.fromPosition(
        TextPosition(offset: _ctrl.text.length),
      );
      setState(() {
        _forwardPackageAttached = false;
        _stagedForward = null;
        _forwardSelectedIds.clear();
        _stagedForwardFileIds.clear();
      });
    } else {
      await ForwardOutbox.putForChat(
        chatId: target.chatId,
        text: payload.encodeForText(),
        fileUrls: uniqueFileUrls,
        fileIds: uniqueFileIds,
      );
      await target.open(context); // в целевом чате пакет вставится в композер
    }
  }

  // Загружаем файлы для старых сообщений (type=file)
  Future<void> _loadOldFiles() async {
    try {
      final teamId = context.read<TeamCubit>().state.team.id;
      final chatId = await _getChatIdForTeam(teamId);
      
      // Получаем все сообщения с type=file
      final response = await Supabase.instance.client
          .from('messages')
          .select('id, file_id')
          .eq('chat_id', chatId)
          .eq('msg_type', 'file')
          .not('file_id', 'is', null);
      
      print('🔍 Найдено ${response.length} старых файловых сообщений');
      
      // Загружаем файлы из chat_files
      for (final msg in response) {
        final fileId = msg['file_id'] as String;
        
        // Проверяем, есть ли уже в кэше
        final cachedFile = _globalCache.getFile(fileId);
        if (cachedFile != null) {
          print('⏭️ Файл уже в кэше, пропускаем: ${cachedFile.fileName}');
          continue;
        }
        
        try {
          print('⏳ Загружаем файл из БД: $fileId');
          final fileResponse = await Supabase.instance.client
              .from('chat_files')
              .select('*')
              .eq('id', fileId)
              .eq('is_deleted', false)
              .single();
          
          if (fileResponse != null) {
            final chatFile = ChatFile.fromJson(fileResponse);
            // Кэшируем файл в глобальном кэше
            await _globalCache.cacheFile(fileId, chatFile);
            // Предзагружаем картинку в диск-кэш, чтобы в ленте не мигало
            if ((chatFile.fileType).startsWith('image/') && chatFile.fileUrl.isNotEmpty) {
              if (!_prefetchedImageUrls.contains(chatFile.fileUrl)) {
                _prefetchedImageUrls.add(chatFile.fileUrl);
                // ignore: unawaited_futures
                precacheImage(CachedNetworkImageProvider(chatFile.fileUrl), context);
              }
            }
            print('✅ Загружен и кэширован в глобальном кэше старый файл: ${chatFile.fileName} для сообщения ${msg['id']}');
          }
        } catch (e) {
          print('❌ Ошибка загрузки файла $fileId: $e');
        }
      }
    } catch (e) {
      print('❌ Ошибка загрузки старых файлов: $e');
    }
  }

  // Удаляем старые методы загрузки файлов - теперь используем attachments из Message

  // Сохраняем файл в chat_files таблицу
  Future<ChatFile> _saveChatFileToDatabase(ChatFile chatFile, String userId) async {
    final id = await _repo.saveChatFile(chatFile, userId);
    return chatFile.copyWith(id: id);
  }

  // Удаляем загруженный файл из БД
  Future<void> _deleteUploadedFile(String fileId) async {
    try {
      await Supabase.instance.client
          .from('chat_files')
          .delete()
          .eq('id', fileId);
      
      print('✅ Файл удален из БД: $fileId');
    } catch (e) {
      print('❌ Ошибка удаления файла из БД: $e');
    }
  }

  



  // Определяем, нужно ли показывать аватар для сообщения
  bool _shouldShowAvatar(List<Message> messages, int currentIndex, String? currentUserId) {
    if (currentIndex == 0) return true; // Первое сообщение всегда показывает аватар
    
    final currentMessage = messages[currentIndex];
    final previousMessage = messages[currentIndex - 1];
    
    // Если предыдущее сообщение от другого автора - показываем аватар
    if (currentMessage.authorId != previousMessage.authorId) return true;
    
    // Если предыдущее сообщение от того же автора, но прошло больше 5 минут - показываем аватар
    final timeDiff = currentMessage.at.difference(previousMessage.at);
    if (timeDiff.inMinutes > 5) return true;
    
    // Если это системное сообщение - всегда показываем
    if (currentMessage.isSystem) return true;
    
    // Если это задание - всегда показываем
    if (currentMessage.type == MessageType.assignmentDraft || 
        currentMessage.type == MessageType.assignmentPublished) return true;
    
    // Если это файл - всегда показываем
    if (currentMessage.type == MessageType.file) return true;
    
    return false; // Не показываем аватар для группированных сообщений
  }

  // Проверяем, является ли дата тем же днем
  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  // Закрепляем текст
  void _pinText(String text) {
    _pinsCtl.pinText(text);
  }

  // Закрепляем задание
  void _pinAssignment(Assignment assignment) {
    _pinsCtl.pinAssignment(assignment);
  }

  // Показываем действия для файла
  void _showFileActions(BuildContext context, ChatFile file) {
    ca.ChatActions.showFileActions(
      context,
      file,
      onDownload: () => _downloadFile(file),
      onOpen: () => _openFile(file),
      onShare: () => _shareFile(file),
    );
  }

  // Открываем файл
  void _openFile(ChatFile file) {
    // Реализация открытия файла
    print('Открытие файла: ${file.fileName}');
  }

  // Делимся файлом
  void _shareFile(ChatFile file) {
    // Реализация шаринга файла
    print('Шаринг файла: ${file.fileName}');
  }

  // Показываем действия для множественных файлов
  void _showMultiFileActions(BuildContext context, List<ChatFile> files) {
    ca.ChatActions.showMultiFileActions(
      context,
      files,
      onDownloadAll: () {
        for (final file in files) {
          _downloadFile(file);
        }
      },
      onOpenAll: () {
        for (final file in files) {
          _openFile(file);
        }
      },
    );
  }

  // Обработка прикрепления файла
  void _onAttachFile(File file) {
    final attachedFile = LocalAttach(
      path: file.path,
      name: file.path.split('/').last,
      mimeType: 'application/octet-stream',
      size: file.lengthSync(),
      isImage: false,
    );
    _att.add(attachedFile);
  }

  // Обработка выбора изображения
  void _onPickImage() async {
    final res = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (res != null) {
      final file = File(res.path);
      final attachedFile = LocalAttach(
        path: res.path,
        name: res.path.split('/').last,
        mimeType: 'image/jpeg',
        size: file.lengthSync(),
        isImage: true,
      );
      _att.add(attachedFile);
      print('📎 Добавлено изображение: ${res.path}');
    }
  }

  // Обработка удаления файла
  void _onRemoveFile(LocalAttach file) {
    _att.remove(file);
  }

  // Обработка добавления файла
  void _onAddFile(LocalAttach file) {
    _att.add(file);
  }

  // Обработка изображения с клавиатуры
  void _onKeyboardImagePicked(String path) async {
    if (path.isNotEmpty && mounted) {
      final file = LocalAttach(
        path: path,
        name: path.split('/').last,
        mimeType: 'image/jpeg',
        size: await File(path).length(),
        isImage: true,
      );
      _att.add(file);
    }
  }

  // Обработка тапа на ответ
  void _onReplyTap(String replyId) {
    _scrollToMessage(replyId);
  }

  // Обработка долгого нажатия на сообщение
  void _onLongPress(BuildContext context, Message message) {
    _showMessageActions(context, message);
  }

  // Обработка реакции
  void _onReact(BuildContext context, String messageId) {
    ca.ChatActions.showReactionPicker(context, (emoji) => _addReaction(messageId, emoji));
  }

  // Обработка закрепления
  void _onPin(BuildContext context, Message message) {
    context.read<TeamCubit>().pinMessage(message.id, true);
  }

  // Обработка открепления
  // removed: duplicate _onUnpin for messages; use unified pin handlers

  // Обработка удаления
  void _onDelete(BuildContext context, Message message) {
    context.read<TeamCubit>().removeMessage(message.id);
  }

  // Обработка ответа
  void _onReply(Message message) {
    _replyTo = message;
    setState(() {});
  }

  // Обработка закрытия ответа
  void _onCloseReply() {
    _replyTo = null;
    setState(() {});
  }

  // Обработка прыжка вниз
  void _onJumpToBottom() {
    _jumpToBottom();
  }

  // Обработка кнопки "Еще"
  void _onMore(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Скрыть ленту'),
              onTap: () {
                Navigator.pop(context);
                setState(() => _pinsCtl.hidden = true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Автозакрепление заданий'),
              trailing: Switch(
                value: _pinsCtl.autoAssignment,
                onChanged: (value) {
                  setState(() => _pinsCtl.autoAssignment = value);
                  Navigator.pop(context);
                },
              ),
            ),
            if (_pinsCtl.pins.isNotEmpty) const Divider(height: 12),
            ..._pinsCtl.pins.map((p) => ListTile(
              leading: Icon(p.icon ?? Icons.push_pin),
              title: Text(p.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: p.subtitle != null ? Text(p.subtitle!) : null,
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _pinsCtl.pins.removeWhere((e) => e.id == p.id)),
              ),
              onTap: () {
                Navigator.pop(context);
                if (p.type == PinType.message && p.refId != null) _scrollToMessage(p.refId!);
                if (p.type == PinType.assignment && p.refId != null) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BlocProvider.value(
                        value: context.read<TeamCubit>(),
                        child: AssignmentDetailsScreen(assignmentId: p.refId!),
                      ),
                    ),
                  );
                }
              },
                         )),
           ],
         ),
       ),
     );
   }

  // Обработка открытия закрепленного элемента
  void _onOpen(PinEntry pin) async {
    switch (pin.type) {
      case PinType.message:
        if (pin.refId != null) {
          await _scrollToMessage(pin.refId!);
        }
        break;
      case PinType.assignment:
        if (pin.refId != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => BlocProvider.value(
                value: context.read<TeamCubit>(),
                child: AssignmentDetailsScreen(assignmentId: pin.refId!),
              ),
            ),
          );
        }
        break;
      case PinType.text:
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pin.title ?? '')));
        break;
    }
  }

  // Обработка открепления закрепленного элемента
  void _onUnpin(PinEntry pin) async {
    switch (pin.type) {
      case PinType.message:
        if (pin.refId != null) {
          await context.read<TeamCubit>().pinMessage(pin.refId!, false);
        }
        break;
      case PinType.assignment:
        // Для заданий открепление не поддерживается
        break;
      case PinType.text:
        _pinsCtl.removePin(pin.id);
        break;
    }
  }



  // Обработка предложения задания
  void _onPropose(String title, String description, String? link, String? due, List<Map<String, String>> attachments) async {
    await context.read<TeamCubit>().proposeAssignment(
      title: title,
      description: description,
      link: link,
      due: due,
      attachments: attachments,
    );
  }

  // Обработка голосования
  void _onVote() async {
    await context.read<TeamCubit>().voteForPending();
  }

  // Обработка публикации
  void _onPublish() async {
    await context.read<TeamCubit>().publishPendingManually();
  }

  // Обработка открытия задания
  void _onOpenAssignment(String assignmentId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: context.read<TeamCubit>(),
          child: AssignmentDetailsScreen(assignmentId: assignmentId),
        ),
      ),
    );
  }

  // Обработка редактирования задания
  void _onEditAssignment(Assignment assignment) async {
    final res = await showEditAssignmentDialog(context, assignment);
    if (res != null) {
      final (title, description, link, due, attachments) = res;
      await context.read<TeamCubit>().updateAssignment(
        assignment.id,
        title: title,
        description: description,
        link: link,
        due: due,
        attachments: attachments,
      );
    }
  }

  // Обработка удаления задания
  void _onDeleteAssignment(Assignment assignment) async {
    await context.read<TeamCubit>().removeAssignment(assignment.id);
  }

  // Обработка закрепления задания
  void _onPinAssignment(Assignment assignment) {
    _pinAssignment(assignment);
  }

  // Обработка открепления задания
  void _onUnpinAssignment(Assignment assignment) {
    // Для заданий открепление не поддерживается
    print('Открепление заданий не поддерживается');
  }

  // Обработка скачивания файла
  void _onDownloadFile(ChatFile file) {
    _downloadFile(file);
  }

  // Обработка открытия файла
  void _onOpenFile(ChatFile file) {
    _openFile(file);
  }

  // Обработка шаринга файла
  void _onShareFile(ChatFile file) {
    _shareFile(file);
  }

  // Обработка скачивания всех файлов
  void _onDownloadAllFiles(List<ChatFile> files) {
    for (final file in files) {
      _downloadFile(file);
    }
  }

  // Обработка открытия всех файлов
  void _onOpenAllFiles(List<ChatFile> files) {
    for (final file in files) {
      _openFile(file);
    }
  }
}












