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
import 'chat/edit_message_dialog.dart';
// ChatActions приходит через реэкспорт из widgets.dart
import '../global_cache.dart';
import '../../../services/image_cache_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';
// Рефакторенные виджеты и контроллеры
import 'chat/widgets.dart';
import 'chat/search/inline_search_bar.dart';
import 'chat/assignments/assignment_form_dialog.dart';
import 'chat/assignments/edit_assignment_dialog.dart';
import 'chat/selection_bars.dart';
import 'chat/topics/create_topic_selection_screen.dart';
import 'chat/collections/create_collection_screen.dart';
import 'chat/data/chat_composer_capabilities_repository.dart';
import 'chat/models/chat_composer_capabilities.dart';
import '../../chats/core/forward_payload.dart';
import '../../chats/data/blocks_api.dart';
import '../../chats/forward/forward_outbox.dart';
import '../../chats/forward/forward_picker.dart';
import '../../chats/forward/forward_pick_nav.dart';
import '../../../services/push/active_chat_tracker.dart';
import '../../../services/push/app_notifications_api.dart';
import '../../../utils/safe_debug_log.dart';
import '../utils/chat_copied_file_cache.dart';

class _ClipboardFileKind {
  final FileFormat format;
  final String extension;
  final String mimeType;
  final bool isImage;

  const _ClipboardFileKind(
    this.format,
    this.extension,
    this.mimeType,
    this.isImage,
  );
}

class _ClipboardFilePayload {
  final Uint8List bytes;
  final String? fileName;
  final _ClipboardFileKind kind;

  const _ClipboardFilePayload({
    required this.bytes,
    required this.fileName,
    required this.kind,
  });
}

class ChatTab extends StatefulWidget {
  final ValueChanged<bool>? onSelectingChanged;

  /// Completed-semester academic chat: view history/files only.
  final bool readOnly;

  /// Deeplink: scroll to and briefly highlight this message in chat history.
  final String? highlightMessageId;

  const ChatTab({
    super.key,
    this.onSelectingChanged,
    this.readOnly = false,
    this.highlightMessageId,
  });
  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> {
  static const bool enableTypingIndicator = false;
  static const List<_ClipboardFileKind> _clipboardFileKinds = [
    _ClipboardFileKind(Formats.png, 'png', 'image/png', true),
    _ClipboardFileKind(Formats.jpeg, 'jpg', 'image/jpeg', true),
    _ClipboardFileKind(Formats.gif, 'gif', 'image/gif', true),
    _ClipboardFileKind(Formats.webp, 'webp', 'image/webp', true),
    _ClipboardFileKind(Formats.bmp, 'bmp', 'image/bmp', true),
    _ClipboardFileKind(Formats.svg, 'svg', 'image/svg+xml', true),
    _ClipboardFileKind(Formats.pdf, 'pdf', 'application/pdf', false),
    _ClipboardFileKind(Formats.doc, 'doc', 'application/msword', false),
    _ClipboardFileKind(
      Formats.docx,
      'docx',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      false,
    ),
    _ClipboardFileKind(Formats.xls, 'xls', 'application/vnd.ms-excel', false),
    _ClipboardFileKind(
      Formats.xlsx,
      'xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      false,
    ),
    _ClipboardFileKind(
      Formats.ppt,
      'ppt',
      'application/vnd.ms-powerpoint',
      false,
    ),
    _ClipboardFileKind(
      Formats.pptx,
      'pptx',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      false,
    ),
    _ClipboardFileKind(Formats.csv, 'csv', 'text/csv', false),
    _ClipboardFileKind(Formats.md, 'md', 'text/markdown', false),
    _ClipboardFileKind(Formats.plainTextFile, 'txt', 'text/plain', false),
    _ClipboardFileKind(Formats.zip, 'zip', 'application/zip', false),
    _ClipboardFileKind(
        Formats.rar, 'rar', 'application/x-rar-compressed', false),
    _ClipboardFileKind(
      Formats.sevenZip,
      '7z',
      'application/x-7z-compressed',
      false,
    ),
  ];
  static final _ClipboardFileKind _genericClipboardImageKind =
      _ClipboardFileKind(
    SimpleFileFormat(mimeTypes: const ['image/*']),
    'png',
    'image/png',
    true,
  );

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
  // Authors I blocked — one RPC per screen open (no N+1).
  Set<String> _blockedUserIds = <String>{};
  final Set<String> _revealedBlockedMessageIds = <String>{};
  bool _loadingOlderMessages = false;
  bool _hasMoreOlderMessages = true;
  String? _trackedChatId;
  // флаг и чип превью «пакет сообщений» в композере
  bool _forwardPackageAttached = false;
  final List<String> _forwardSelectedIds = [];
  final List<String> _stagedForwardFileIds = [];
  final _capsRepo = ChatComposerCapabilitiesRepository();
  ChatComposerCapabilities? _composerCaps;
  bool _capsLoading = true;
  bool _canDeleteMessage(Message m) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty || m.authorId != uid) return false;
    return DateTime.now().difference(m.at) <= const Duration(hours: 12);
  }

  void _exitSelection() {
    _selectedMessageIds.clear();
    _setSelecting(false);
  }

  void _showSelectionSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  List<Message> _selectedMessagesFrom(List<Message> list) {
    return list.where((m) => _selectedMessageIds.contains(m.id)).toList()
      ..sort((a, b) => a.at.compareTo(b.at));
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

  Future<void> _copySelectedMessages(List<Message> selected) async {
    if (selected.isEmpty) {
      _showSelectionSnack('Нечего копировать');
      return;
    }
    if (selected.length == 1) {
      try {
        await ca.ChatActions.copyMessageToClipboard(selected.first);
        _showSelectionSnack('Скопировано');
      } catch (_) {
        _showSelectionSnack('Не удалось скопировать');
      }
      return;
    }
    final text = selected
        .map((m) => m.text.trim())
        .where((t) => t.isNotEmpty)
        .join('\n\n');
    if (text.isEmpty) {
      _showSelectionSnack('Нечего копировать');
      return;
    }
    await services.Clipboard.setData(services.ClipboardData(text: text));
    _showSelectionSnack('Скопировано');
  }

  Future<void> _deleteSelectedMessages(List<Message> selected) async {
    final deletable = selected.where(_canDeleteMessage).toList();
    if (deletable.isEmpty) {
      _showSelectionSnack(
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
        await context.read<TeamCubit>().removeMessage(m.id);
      } catch (_) {
        if (!mounted) return;
        _showSelectionSnack('Не удалось удалить сообщение');
        return;
      }
    }
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _forwardSelectedMessages(List<Message> selected) async {
    if (selected.isEmpty) return;
    _exitSelection();
    await _startForwardSelection(selected);
  }

  bool _canEditMessage(Message m) => canEditOwnTextMessage(
        m,
        Supabase.instance.client.auth.currentUser?.id,
      );

  Future<void> _editMessage(Message m) async {
    await showEditMessageDialog(
      context,
      initialText: m.text,
      onSave: (text) async {
        final updated =
            await context.read<TeamCubit>().editOwnMessage(m.id, text);
        if (updated == null) {
          throw Exception('edit_failed');
        }
      },
    );
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
  String? _deeplinkHighlightId;
  bool _deeplinkHighlightStarted = false;

  final Set<String> _typingUsers = {};
  Timer? _myTypingOff;
  List<String> get _visibleTypingUsers =>
      _typingUsers.where((name) => name != 'Вы').toList();
  bool get _someoneTyping =>
      enableTypingIndicator && _visibleTypingUsers.isNotEmpty;

  // Блокировка повторных отправок и индикатор фоновых загрузок
  bool _isSending = false;
  bool get _isUploadingAttachments => _att.hasActiveUploads;
  bool get _hasFailedAttachments => _att.hasFailedUploads;

  // Файлы в чате
  final FileService _fileService = FileService();
  late final ChatRepository _repo;
  // «граница на входе»: момент времени, до которого было прочитано при открытии
  DateTime? _entrySeenAt;
  // Показывать ли «Новые сообщения» в эту сессию (замораживаем на входе)
  bool _showEntryNewBadge = false;
  String _lastPrecachedImageSignature = '';

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
    final timeStr =
        '${m.at.hour.toString().padLeft(2, '0')}:${m.at.minute.toString().padLeft(2, '0')}';
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
          final int unreadCount =
              (unread['unread_count'] ?? unread['count'] ?? 0) as int;
          showBadge =
              (firstId != null && firstId.isNotEmpty) || unreadCount > 0;
        } catch (_) {
          final listNow = context.read<TeamCubit>().state.chat;
          showBadge = listNow.any((m) => m.at.toUtc().isAfter(entry!));
        }
      }
      if (!mounted) return;
      setState(() {
        _entrySeenAt = entry; // freeze boundary на всю сессию
        _showEntryNewBadge = showBadge; // freeze показываемость на момент входа
      });
    } catch (_) {}
  }

  Future<void> _loadBlockedUserIds() async {
    try {
      final ids = await BlocksApi.getMyBlockedUserIds();
      if (!mounted) return;
      setState(() => _blockedUserIds = ids);
    } catch (e) {
      debugPrint('[ChatTab] getMyBlockedUserIds error: $e');
    }
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
    _att = ChatAttachmentsController(
        _fileService, _globalCache, Supabase.instance.client)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _repo = ChatRepository(
        supabase: Supabase.instance.client, fileService: _fileService);

    // Добавляем слушатель для поля поиска
    _search.field.addListener(() {
      if (mounted) {
        _search.recompute(
            context.read<TeamCubit>().state.chat, _isMessageMatched);
      }
    });

    // Автопрокрутка при смене текущей цели поиска
    _search.addListener(() async {
      if (!mounted) return;
      final id = _search.currentTargetId;
      if (_search.isActive && id.isNotEmpty && id != _lastAutoScrollTarget) {
        _lastAutoScrollTarget = id;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _scrollToMessage(id));
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

    // One blocked-authors snapshot for this group/team screen.
    // ignore: discarded_futures
    _loadBlockedUserIds();

    // Composer + capabilities (stable menu; independent of message list).
    // ignore: discarded_futures
    _loadComposerCapabilities();

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
        if (!mounted) return;
        if (chatId.isNotEmpty) {
          _trackedChatId = chatId;
          ActiveChatTracker.instance.enter(chatId);
        }
        await _consumeForwardOutboxIfAny(chatId);
      }();

      // Асинхронно фиксируем «границу на входе» по last_read_at / first_unread_id
      _initEntryBoundary();

      // Prefetch изображений для текущей ленты
      final imgs = context
          .read<TeamCubit>()
          .state
          .chat
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
    ActiveChatTracker.instance.leave(_trackedChatId);
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
    try {
      _keyboardChannel.invokeMethod('dispose');
    } catch (_) {}

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

  void _precacheRecentChatImages(List<Message> messages) {
    final urls = <String>[];
    for (final message in messages.reversed) {
      for (final file in message.attachments ?? const <ChatFile>[]) {
        if (file.isImage && file.fileUrl.isNotEmpty) {
          urls.add(file.fileUrl);
          if (urls.length >= 6) break;
        }
      }
      if (urls.length >= 6) break;
    }

    if (urls.isEmpty) return;
    final signature = urls.join('|');
    if (signature == _lastPrecachedImageSignature) return;
    _lastPrecachedImageSignature = signature;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final url in urls) {
        precacheImage(CachedNetworkImageProvider(url), context);
      }
    });
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
    final anchor = _chatScroll.capturePrependAnchor();
    _loadingOlderMessages = true;
    if (mounted) setState(() {});

    try {
      final loaded =
          await context.read<TeamCubit>().loadOlderMessages(limit: 50);
      if (loaded.length < 50) {
        _hasMoreOlderMessages = false;
      }
      await _chatScroll.restorePrependAnchor(anchor);
    } catch (_) {
      // Keep hasMore so a failed page load can be retried.
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
      try {
        await AppNotificationsApi().markReadForChat(chatId);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[ChatTab] notification read sync error: $e');
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ChatTab] markRead error: $e');
    }
  }

  Future<void> _pickAndUploadFileForComposer() async {
    final file = await _fileService.pickFile();
    if (file == null || !mounted) return;

    final path = file.path;
    final lower = path.toLowerCase();
    final isImage = lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
    final attached = LocalAttach(
      path: path,
      name: path.split('/').last,
      mimeType: isImage
          ? (lower.endsWith('.png')
              ? 'image/png'
              : lower.endsWith('.gif')
                  ? 'image/gif'
                  : lower.endsWith('.webp')
                      ? 'image/webp'
                      : 'image/jpeg')
          : 'application/octet-stream',
      size: await file.length(),
      isImage: isImage,
    );
    _att.add(attached);
    final teamId = context.read<TeamCubit>().state.team.id;
    final chatId = await _getChatIdForTeam(teamId);
    // ignore: unawaited_futures
    _att.upload(attached, teamId: teamId, chatId: chatId);
  }

  Future<void> _queueAndUploadAttachments(List<LocalAttach> files) async {
    if (files.isEmpty || !mounted) return;

    final teamId = context.read<TeamCubit>().state.team.id;
    final chatId = await _getChatIdForTeam(teamId);
    var added = 0;
    var skipped = 0;

    for (final file in files) {
      if (_att.add(file)) {
        added++;
        unawaited(_att.upload(file, teamId: teamId, chatId: chatId));
      } else {
        skipped++;
      }
    }

    if (skipped > 0 && mounted) {
      final message = added > 0
          ? 'Добавлено $added. Остальное: лимит ${ChatAttachmentsController.maxFiles} файла или дубль.'
          : 'Можно добавить не больше ${ChatAttachmentsController.maxFiles} файлов, дубли не добавляются';
      _showSnack(message);
    }
  }

  Future<void> _queueAndUploadAttachment(LocalAttach file) async {
    await _queueAndUploadAttachments([file]);
  }

  Future<void> _pasteFileFromClipboard() async {
    try {
      final plainText =
          await services.Clipboard.getData(services.Clipboard.kTextPlain);
      final text = plainText?.text;
      if (text != null && text.isNotEmpty) {
        await ChatCopiedFileCache.clear();
        _insertPlainText(text);
        return;
      }

      final cached = await ChatCopiedFileCache.peek();
      if (cached != null) {
        final file = File(cached.path);
        safeDebugLog(
            '[ChatTab] paste using internal copied file name=${cached.name}');
        await _attachClipboardFile(
          file: file,
          name: cached.name,
          mimeType: cached.mimeType,
          isImage: cached.isImage,
          existingFileId: cached.fileId,
        );
        return;
      }

      safeDebugLog('[ChatTab] paste fallback to system clipboard');
      final clipboard = SystemClipboard.instance;
      if (clipboard == null) {
        _showSnack('Буфер обмена недоступен на этом устройстве');
        return;
      }

      final reader = await clipboard.read();
      final pasted = await _readClipboardFile(reader);
      if (pasted == null) {
        await _pastePlainTextFromClipboard();
        return;
      }

      final dir = await getTemporaryDirectory();
      final pasteDir =
          Directory('${dir.path}${Platform.pathSeparator}chat_clipboard');
      if (!await pasteDir.exists()) {
        await pasteDir.create(recursive: true);
      }

      final fileName = _safeClipboardFileName(
        pasted.fileName,
        pasted.kind.extension,
      );
      final uniqueName = '${DateTime.now().microsecondsSinceEpoch}_$fileName';
      final file = File('${pasteDir.path}${Platform.pathSeparator}$uniqueName');
      await file.writeAsBytes(pasted.bytes, flush: true);

      await _attachClipboardFile(
        file: file,
        name: fileName,
        mimeType: pasted.kind.mimeType,
        isImage: pasted.kind.isImage,
      );
    } catch (e) {
      safeDebugLog('[ChatTab] paste file failed: ${e.runtimeType}');
      if (!mounted) return;
      _showSnack('Не удалось вставить файл из буфера');
    }
  }

  Future<void> _pastePlainTextFromClipboard() async {
    final data =
        await services.Clipboard.getData(services.Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      _showSnack('В буфере нет файла, изображения или текста');
      return;
    }

    await ChatCopiedFileCache.clear();
    _insertPlainText(text);
  }

  void _insertPlainText(String text) {
    final selection = _ctrl.selection;
    final value = _ctrl.text;
    final start = selection.isValid
        ? selection.start.clamp(0, value.length)
        : value.length;
    final end =
        selection.isValid ? selection.end.clamp(0, value.length) : value.length;
    final nextText = value.replaceRange(start, end, text);
    final cursor = start + text.length;
    _ctrl.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  Future<void> _attachClipboardFile({
    required File file,
    required String name,
    required String mimeType,
    required bool isImage,
    String? existingFileId,
  }) async {
    final reusedFileId = existingFileId?.trim();
    final attached = LocalAttach(
      path: file.path,
      name: name,
      mimeType: mimeType,
      size: await file.length(),
      isImage: isImage,
      uploadStatus: (reusedFileId != null && reusedFileId.isNotEmpty)
          ? LocalAttachUploadStatus.uploaded
          : LocalAttachUploadStatus.queued,
      progress: (reusedFileId != null && reusedFileId.isNotEmpty) ? 1 : 0,
      uploadedFileId: (reusedFileId != null && reusedFileId.isNotEmpty)
          ? reusedFileId
          : null,
    );
    safeDebugLog(
        '[ChatTab] pasted attachment queued name=$name size=${attached.size}');
    if (reusedFileId != null && reusedFileId.isNotEmpty) {
      if (_att.add(attached)) {
        setState(() {});
      } else {
        _showSnack(
            'Можно добавить не больше ${ChatAttachmentsController.maxFiles} файлов или это дубль');
      }
      return;
    }
    await _queueAndUploadAttachment(attached);
  }

  Future<_ClipboardFilePayload?> _readClipboardFile(
    ClipboardReader reader,
  ) async {
    final suggestedName = await reader.getSuggestedName();

    for (final kind in _clipboardFileKinds) {
      final bytes = await _readClipboardBytes(reader, kind.format);
      if (bytes != null && bytes.isNotEmpty) {
        return _ClipboardFilePayload(
          bytes: bytes,
          fileName: suggestedName,
          kind: kind,
        );
      }
    }
    final genericImageBytes =
        await _readClipboardBytes(reader, _genericClipboardImageKind.format);
    if (genericImageBytes != null && genericImageBytes.isNotEmpty) {
      return _ClipboardFilePayload(
        bytes: genericImageBytes,
        fileName: suggestedName,
        kind: _genericClipboardImageKind,
      );
    }

    final fileUri = await reader.readValue(Formats.fileUri);
    if (fileUri != null && fileUri.isScheme('file')) {
      final file = File(fileUri.toFilePath());
      if (await file.exists()) {
        final name = file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : suggestedName;
        final kind = _kindFromName(name ?? file.path);
        return _ClipboardFilePayload(
          bytes: await file.readAsBytes(),
          fileName: name,
          kind: kind,
        );
      }
    }

    return null;
  }

  Future<Uint8List?> _readClipboardBytes(
    ClipboardReader reader,
    FileFormat format,
  ) {
    final completer = Completer<Uint8List?>();
    final progress = reader.getFile(
      format,
      (file) async {
        try {
          completer.complete(await file.readAll());
        } catch (e) {
          completer.completeError(e);
        }
      },
      onError: (error) => completer.completeError(error),
    );
    if (progress == null) {
      completer.complete(null);
    }
    return completer.future;
  }

  _ClipboardFileKind _kindFromName(String name) {
    final lower = name.toLowerCase();
    for (final kind in _clipboardFileKinds) {
      if (lower.endsWith('.${kind.extension}')) return kind;
    }
    return _ClipboardFileKind(
      SimpleFileFormat(mimeTypes: const ['application/octet-stream']),
      'bin',
      'application/octet-stream',
      false,
    );
  }

  String _safeClipboardFileName(String? rawName, String extension) {
    final fallback = 'clipboard_${DateTime.now().millisecondsSinceEpoch}';
    var name = (rawName ?? fallback).trim();
    if (name.isEmpty) name = fallback;
    name = name.split('?').first.split(RegExp(r'[\\/]')).last.trim();
    name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
    if (!name.toLowerCase().endsWith('.$extension')) {
      name = '$name.$extension';
    }
    return name;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _createAssignmentFromComposerAction() async {
    final res = await showAssignmentFormDialog(context);
    if (res == null || !mounted) return;

    try {
      await context.read<TeamCubit>().proposeAssignment(
            title: res.$1,
            description: res.$2,
            link: res.$3,
            due: res.$4,
            attachments: res.$5,
          );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось создать задание в чате. Попробуйте ещё раз.',
          ),
        ),
      );
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

  Future<void> _jumpToBottomAfterSend() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _jumpToBottom();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (!mounted) return;
    await _jumpToBottom();
    await Future<void>.delayed(const Duration(milliseconds: 420));
    if (!mounted) return;
    await _jumpToBottom();
  }

  // ➜ NEW: debounce + проверка «видим ли нижний край», затем отметить прочитанным
  void _scheduleSeenCheck() {
    _seenDebounce?.cancel();
    _seenDebounce =
        Timer(const Duration(milliseconds: 150), _markLastSeenIfNeeded);
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

  Future<void> _runDeeplinkHighlight(String messageId) async {
    if (!mounted || messageId.trim().isEmpty) return;
    final cubit = context.read<TeamCubit>();
    final found = await cubit.ensureMessageVisible(messageId);
    if (!mounted) return;
    if (!found) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Сообщение не найдено или недоступно.'),
        ),
      );
      return;
    }
    await _scrollToMessage(messageId);
    if (!mounted) return;
    setState(() => _deeplinkHighlightId = messageId);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_deeplinkHighlightId == messageId) {
        setState(() => _deeplinkHighlightId = null);
      }
    });
  }

  // Функция добавления реакции - используется в ChatActions
  Future<void> _addReaction(String msgId, String emoji) async {
    // call RPC to toggle reaction; repository will update DB and realtime will sync
    try {
      safeDebugLog(
          '[ChatTab] toggleReaction calling message=${maskDebugId(msgId)}');
      final res = await _repo.toggleReaction(msgId, emoji);
      safeDebugLog(
          '[ChatTab] toggleReaction completed message=${maskDebugId(msgId)} resultType=${res.runtimeType}');
    } catch (e, st) {
      safeDebugLog(
          '[ChatTab] toggleReaction failed message=${maskDebugId(msgId)} error=${e.runtimeType}');
      safeDebugLog('[ChatTab] toggleReaction stack=$st');
    }
  }

  // Сохраняем черновик в глобальный кэш
  Future<void> _saveDraft() async {
    if (_currentChatId != null) {
      final filesData = _att.pending
          .map((f) => {
                'localId': f.localId,
                'path': f.path,
                'name': f.name,
                'mimeType': f.mimeType,
                'size': f.size,
                'isImage': f.isImage,
                'uploadStatus': f.uploadStatus.name,
                'progress': f.progress,
                'uploadedFileId': f.uploadedFileId,
              })
          .toList();

      await _globalCache.saveDraft(_currentChatId!, _ctrl.text, filesData);
      safeDebugLog(
          '[ChatTab] draft saved chat=${maskDebugId(_currentChatId)} files=${filesData.length} hasText=${_ctrl.text.trim().isNotEmpty}');
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
          final uploadedFileId = fileData['uploadedFileId'] as String?;
          final restoredStatus = (uploadedFileId?.isNotEmpty ?? false)
              ? LocalAttachUploadStatus.uploaded
              : LocalAttachUploadStatus.failed;
          _att.pending.add(LocalAttach(
            localId: fileData['localId'] as String?,
            path: fileData['path'] as String? ?? '',
            name: fileData['name'] as String? ?? '',
            mimeType: fileData['mimeType'] as String? ?? '',
            size: fileData['size'] as int? ?? 0,
            isImage: fileData['isImage'] as bool? ?? false,
            uploadStatus: restoredStatus,
            progress:
                restoredStatus == LocalAttachUploadStatus.uploaded ? 1 : 0,
            errorMessage: restoredStatus == LocalAttachUploadStatus.failed
                ? 'Не удалось загрузить'
                : null,
            uploadedFileId: uploadedFileId,
          ));
        }

        safeDebugLog(
            '[ChatTab] draft restored chat=${maskDebugId(_currentChatId)} files=${filesData.length} hasText=${text.trim().isNotEmpty}');

        if (mounted) {
          setState(
              () {}); // Обновляем UI для отображения восстановленных файлов
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
    if (_isUploadingAttachments || _hasFailedAttachments || _isSending) return;

    _isSending = true;
    setState(() {});
    var shouldJumpAfterSend = false;
    try {
      // если это пакет из другого чата (есть _stagedForward)
      if (_stagedForward != null && _forwardPackageAttached) {
        final teamId = context.read<TeamCubit>().state.team.id;
        final forwardPayload = _stagedForward!;
        final rawComposerText = _ctrl.text.trim();
        final caption = ForwardPayload.isForwardText(rawComposerText)
            ? null
            : rawComposerText;
        final forwardText = ForwardPayload(
          fromChatId: forwardPayload.fromChatId,
          caption: caption ?? forwardPayload.caption,
          items: forwardPayload.items,
        ).encodeForText();

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
          }
        }

        final fileIds = collectedIds.toList();

        await _sendMessageWithFilesAndRefresh(teamId, forwardText, fileIds);
        setState(() {
          _forwardPackageAttached = false;
          _stagedForward = null;
          _forwardSelectedIds.clear();
          _stagedForwardFileIds.clear();
          _att.clear();
          _ctrl.clear();
        });
        await _jumpToBottomAfterSend();
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
            text: (m.text ?? '').trim(),
            files: files,
          ));
        }

        final fromChatId = await _getChatIdForTeam(teamId);
        final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
        final payload = ForwardPayload(
            fromChatId: fromChatId, caption: caption, items: items);

        final uniqueFileIds = fileIds.toSet().toList();
        await _sendMessageWithFilesAndRefresh(
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
        await _jumpToBottomAfterSend();
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
        await context.read<TeamCubit>().sendMessage(
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
      shouldJumpAfterSend = true;
    } finally {
      _isSending = false;
      if (mounted) setState(() {});
      if (shouldJumpAfterSend) {
        await _jumpToBottomAfterSend();
      }
    }
  }

  Future<bool> _sendMessageWithFiles(
      String text, String? replyId, List<LocalAttach> filesToSend) async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⏳ Файлы загружаются, подождите...')),
        );
        return false;
      }

      // Вызываем новую RPC для отправки сообщения с файлами
      await _sendMessageWithFilesAndRefresh(
        context.read<TeamCubit>().state.team.id,
        text,
        fileIds,
      );

      // Очищаем список прикрепленных файлов
      _att.clear();

      return true;
    } catch (e) {
      safeDebugLog('[ChatTab] sendMessageWithFiles failed: ${e.runtimeType}');
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
        fileName: _baseName(file.path),
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
      await Supabase.instance.client.from('chat_files').update({
        'file_key': uploadResult.fileKey,
        'file_url': uploadResult.fileUrl,
        'file_type': uploadResult.fileType,
        'file_size': uploadResult.fileSize,
      }).eq('id', savedChatFile.id);

      safeDebugLog(
          '[ChatTab] uploaded file metadata saved id=${maskDebugId(savedChatFile.id)}');

      // Если messageId не передан, создаем сообщение с файлом через репозиторий
      if (messageId == null) {
        final newMessageId = await _sendMessageWithFilesAndRefresh(
          teamId,
          '📎 ${uploadResult.fileName}',
          [savedChatFile.id],
        );
        safeDebugLog(
            '[ChatTab] file message created message=${maskDebugId(newMessageId)}');
      }

      // Файлы теперь загружаются автоматически через attachments в Message
      safeDebugLog(
          '[ChatTab] file upload completed id=${maskDebugId(savedChatFile.id)}');

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

  Future<String> _sendMessageWithFilesAndRefresh(
    String teamId,
    String text,
    List<String> fileIds,
  ) async {
    final messageId = await _repo.sendMessageWithFiles(teamId, text, fileIds);
    if (messageId.isNotEmpty && mounted) {
      await context.read<TeamCubit>().refreshMessageById(messageId);
    }
    return messageId;
  }

  String _baseName(String path) {
    return path.split(RegExp(r'[\\/]')).last;
  }

  void _showFileUploadSheet(BuildContext context) {
    // Простое меню выбора файла
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isDismissible: true,
      enableDrag: true,
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
              previous.assignments != current.assignments ||
              previous.loading != current.loading;
        },
        builder: (context, state) {
          final safeBottom = MediaQuery.of(context).padding.bottom;
          const bottomActionsContent =
              64.0; // кнопки ~44 + вертикальные паддинги
          const listPadBottom = 8.0;
          final jumpBottom = _selectingMessages
              ? (safeBottom + bottomActionsContent + 20)
              : (safeBottom + 82.0);
          final list = state.chat;
          if (list.isNotEmpty) {
            _precacheRecentChatImages(list);
          }
          final pins = _pinsCtl.buildFromState(state);
          // prune keys to avoid leaks
          _pruneMessageKeys(list.map((m) => m.id).toSet());
          _pruneBoundaryKeys(list.map((m) => m.id).toSet());

          // Обновляем поиск при изменении чата
          if (_search.isActive) {
            _search.recompute(list, _isMessageMatched);
          }

          // ➜ NEW: если пришёл новый последний id и мы держим низ — отметить прочитанным
          if (!_deeplinkHighlightStarted &&
              widget.highlightMessageId != null &&
              state.chatHasSnapshot) {
            _deeplinkHighlightStarted = true;
            final targetId = widget.highlightMessageId!.trim();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _runDeeplinkHighlight(targetId);
            });
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

          // initialScrollOffset уже сдвигает в конец, доп.скролл не нужен

          final readOnly = widget.readOnly;

          return Column(
            children: [
              if (_selectingMessages)
                TopSelectionBar(
                  count: _selectedMessageIds.length,
                  onClose: _exitSelection,
                ),
              if (readOnly)
                Material(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.72),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 16,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.62),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Семестр завершён. Чат доступен только для просмотра',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.72),
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_search.isActive)
                InlineSearchBar(
                  controller: _search,
                  onClose: () => _search.setActive(false),
                )
              else if (!_selectingMessages &&
                  !_pinsCtl.hidden &&
                  pins.isNotEmpty)
                PinnedStripContainer(
                  pins: pins,
                  controller: _pinsCtl,
                  onOpen: _onOpen,
                  onUnpin: readOnly
                      ? null
                      : (p) async {
                          if (p.type == PinType.message && p.refId != null) {
                            await context
                                .read<TeamCubit>()
                                .pinMessage(p.refId!, false);
                          }
                        },
                ),

              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    FocusScope.of(context).unfocus();
                    _forceSaveDraft();
                    if (_search.isActive) {
                      _search.clear();
                      _search.setActive(false);
                    }
                    if (_selectingMessages) {
                      _exitSelection();
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
                          currentUserId:
                              Supabase.instance.client.auth.currentUser?.id,
                          entrySeenAt: _entrySeenAt,
                          showEntryNewBadge: _showEntryNewBadge,
                          hoveredMessageId:
                              _deeplinkHighlightId ?? _actionsHoverId,
                          initialLoading: state.chatInitialLoading,
                          loadError: state.chatError && !state.chatHasSnapshot,
                          onRetryLoad: () {
                            unawaited(
                                context.read<TeamCubit>().retryLoadChat());
                          },
                          blockedUserIds: _blockedUserIds,
                          revealedBlockedMessageIds: _revealedBlockedMessageIds,
                          onRevealBlockedMessage: (id) {
                            setState(() => _revealedBlockedMessageIds.add(id));
                          },
                          onReply: readOnly
                              ? (_) {}
                              : (m) {
                                  setState(() => _replyTo = m);
                                },
                          onLongPress: readOnly
                              ? (_, __, ___, ____, _____, ______) {}
                              : (ctx, m, rect, bytes, replyPreview, fallback) =>
                                  _showMessageActions(ctx, m,
                                      targetRect: rect,
                                      bubbleBytes: bytes,
                                      replyPreview: replyPreview,
                                      fallbackPosition: fallback),
                          onReplyTap: (id) => _scrollToMessage(id),
                          onReact: readOnly
                              ? (_, __) {}
                              : (ctx, id) => ca.ChatActions.showReactionPicker(
                                    ctx,
                                    (emoji) => _addReaction(id, emoji),
                                  ),
                          onReactionSelected: readOnly ? null : _addReaction,
                          canDeleteMessage:
                              readOnly ? (_) => false : _canDeleteMessage,
                          canEditMessage:
                              readOnly ? (_) => false : _canEditMessage,
                          onMenuAction:
                              readOnly ? null : _handlePackageMenuAction,
                          onRetryFailedText: (m) => context
                              .read<TeamCubit>()
                              .retryFailedTextMessage(m),
                          onFocusComposer: () {
                            _composerFocus.requestFocus();
                            services.SystemChannels.textInput
                                .invokeMethod('TextInput.show');
                          },
                          onAttachFile: () {
                            // ignore: unawaited_futures
                            _pickAndUploadFileForComposer();
                          },
                          onCreateAssignment: () {
                            // ignore: unawaited_futures
                            _createAssignmentFromComposerAction();
                          },
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
                            if (_selectedMessageIds.isEmpty &&
                                _selectingMessages) {
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
                      if (_showJump)
                        Positioned(
                          right: 12,
                          bottom: _selectingMessages ? 20 : jumpBottom,
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

              if (_selectingMessages)
                Builder(
                  builder: (_) {
                    final selected = _selectedMessagesFrom(state.chat);
                    final canDeleteAny = selected.any(_canDeleteMessage);
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
                      onUnavailable: _showSelectionSnack,
                    );
                  },
                )
              else if (!readOnly)
                ChatComposerBar(
                  controller: _ctrl,
                  focusNode: _composerFocus,
                  replyTo: _replyTo,
                  onCloseReply: () {
                    setState(() => _replyTo = null);
                  },
                  forwardCount: _forwardPackageAttached
                      ? (_stagedForward?.items.length ??
                          _forwardSelectedIds.length)
                      : 0,
                  forwardPreview: _forwardComposerPreview(),
                  onCancelForward: _forwardPackageAttached
                      ? () {
                          setState(() {
                            _forwardPackageAttached = false;
                            _stagedForward = null;
                            _forwardSelectedIds.clear();
                            _stagedForwardFileIds.clear();
                            _att.pending.removeWhere((x) => x.path == '__FG__');
                          });
                        }
                      : null,
                  someoneTyping: _someoneTyping,
                  typingNames: _visibleTypingUsers,
                  attachedFiles: _att.pending.map((f) {
                    return AttachedFile(
                      localId: f.localId,
                      path: f.path,
                      name: f.name,
                      isImage: f.isImage,
                      size: f.size,
                      uploadStatus: f.uploadStatus,
                      progress: f.progress,
                      errorMessage: f.errorMessage,
                      uploadedFileId: f.uploadedFileId,
                    );
                  }).toList(),
                  isUploading: _isUploadingAttachments,
                  hasFailedUploads: _hasFailedAttachments,
                  isSending: _isSending,
                  showProposeInPlus: !readOnly &&
                      (_composerCaps?.showProposeAssignment ?? true),
                  showTopicSelectionInPlus: !readOnly &&
                      (_composerCaps?.showTopicSelection ??
                          (!state.team.isGroupSpaceChat)),
                  showCollectionInPlus: !readOnly &&
                      (_composerCaps?.showCollection ??
                          state.team.isGroupSpaceChat),
                  capabilitiesLoading: !readOnly && _capsLoading,
                  proposeEnabled: !readOnly &&
                      (_composerCaps?.canProposeAssignment ?? false),
                  topicSelectionEnabled: !readOnly &&
                      (_composerCaps?.canCreateTopicSelection ?? false),
                  collectionEnabled: !readOnly &&
                      (_composerCaps?.canCreateCollection ?? false),
                  proposeDisabledReason:
                      _composerCaps?.reasonLabel('propose_assignment'),
                  topicSelectionDisabledReason:
                      _composerCaps?.reasonLabel('topic_selection'),
                  collectionDisabledReason:
                      _composerCaps?.reasonLabel('collection'),
                  onOpenTopicSelection: () =>
                      unawaited(_openTopicSelection(context)),
                  onOpenCollection: () => unawaited(_openCollection(context)),
                  onSend: () => _send(context),
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
                  onRetryFile: (ui) async {
                    final local =
                        _att.pending.firstWhere((f) => f.localId == ui.localId);
                    final teamId = context.read<TeamCubit>().state.team.id;
                    final chatId = await _getChatIdForTeam(teamId);
                    await _att.retry(local, teamId: teamId, chatId: chatId);
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
                      final local = _att.pending
                          .firstWhere((f) => f.localId == ui.localId);
                      if (local.canCancel) {
                        _att.cancel(local);
                      } else {
                        _att.remove(local);
                      }
                    }
                  },
                  onPickImage: () async {
                    final images = await _fileService.pickImages();
                    final attachments = <LocalAttach>[];
                    for (final image in images) {
                      attachments.add(
                        LocalAttach(
                          path: image.path,
                          name: image.path.split(RegExp(r'[\\/]')).last,
                          mimeType: 'image/jpeg',
                          size: await image.length(),
                          isImage: true,
                        ),
                      );
                    }
                    await _queueAndUploadAttachments(attachments);
                  },
                  onOpenEmoji: () {
                    _composerFocus.requestFocus();
                    services.SystemChannels.textInput
                        .invokeMethod('TextInput.show');
                  },
                  onAttachFile: () async {
                    final files = await _fileService.pickFiles();
                    final attachments = <LocalAttach>[];
                    for (final file in files) {
                      attachments.add(
                        LocalAttach(
                          path: file.path,
                          name: file.path.split(RegExp(r'[\\/]')).last,
                          mimeType: 'application/octet-stream',
                          size: await file.length(),
                          isImage: false,
                        ),
                      );
                    }
                    await _queueAndUploadAttachments(attachments);
                  },
                  onPasteFile: _pasteFileFromClipboard,
                  onPinText: (text) => _pinsCtl.pinText(text),
                  onFind: () async {
                    // Показать ТОЛЬКО верхнюю строку поиска, без нижнего листа
                    FocusScope.of(context).unfocus();
                    _search.setActive(true);
                  },
                  onPropose:
                      (title, description, link, due, attachments) async {
                    try {
                      await context.read<TeamCubit>().proposeAssignment(
                            title: title,
                            description: description,
                            link: link,
                            due: due,
                            attachments: attachments,
                          );
                    } catch (_) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Не удалось создать задание в чате. Попробуйте ещё раз.',
                          ),
                        ),
                      );
                    }
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  // Функция показа действий с сообщением - используется в ChatActions
  void _showMessageActions(BuildContext context, Message m,
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
          final overlayBox = Overlay.of(context, rootOverlay: true)
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

    // включаем временную подсветку «как будто выделено»
    setState(() => _actionsHoverId = m.id);

    try {
      await ca.ChatActions.showMessageActions(
        context,
        m,
        targetRect: finalRect,
        bubbleBytes: null,
        replyPreview: replyPreview,
        fallbackPosition: fallbackPosition,
        onReply: () {
          _replyTo = m;
          setState(() {});
        },
        onForward: () async {
          await _startForwardSelection(<Message>[m]);
        },
        onTogglePin: () =>
            context.read<TeamCubit>().pinMessage(m.id, !m.isPinned),
        onDeleteIfAllowed: () => context.read<TeamCubit>().removeMessage(m.id),
        onEditIfAllowed: _canEditMessage(m) ? () => _editMessage(m) : null,
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

  Future<void> _handlePackageMenuAction(Message m, String action) async {
    switch (action) {
      case 'Ответить':
        setState(() => _replyTo = m);
        break;
      case 'Скопировать':
        final text = m.text.trim();
        if (text.isNotEmpty) {
          await services.Clipboard.setData(services.ClipboardData(text: text));
        }
        break;
      case 'Изменить':
        if (_canEditMessage(m)) {
          await _editMessage(m);
        }
        break;
      case 'Закрепить':
      case 'Открепить':
        await context.read<TeamCubit>().pinMessage(m.id, !m.isPinned);
        break;
      case 'Переслать':
        await _startForwardSelection(<Message>[m]);
        break;
      case 'Удалить':
        if (_canDeleteMessage(m)) {
          await context.read<TeamCubit>().removeMessage(m.id);
        }
        break;
      case 'Выбрать':
        _selectedMessageIds.add(m.id);
        _setSelecting(true);
        break;
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
  Future<String> _getChatIdForTeam(String teamId) =>
      _repo.getMainChatId(teamId);

  Future<void> _loadComposerCapabilities() async {
    if (!mounted) return;
    final teamState = context.read<TeamCubit>().state;
    final team = teamState.team;
    final structural = ChatComposerCapabilities.structuralLoading(
      teamKind: team.kind,
      isDm: false,
    );
    setState(() {
      _composerCaps = _composerCaps ?? structural;
      _capsLoading = true;
    });
    try {
      final chatId = await _getChatIdForTeam(team.id);
      final caps = await _capsRepo.load(
        chatId,
        fallbackTeamKind: team.kind,
        localIsOrganizer: teamState.isStarosta,
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
    if (_composerCaps?.canCreateTopicSelection != true) {
      _showSelectionSnack(
        _composerCaps?.reasonLabel('topic_selection') ?? 'Недоступно',
      );
      return;
    }
    final teamId = context.read<TeamCubit>().state.team.id;
    final chatId = await _getChatIdForTeam(teamId);
    if (chatId.isEmpty || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CreateTopicSelectionScreen(chatId: chatId),
      ),
    );
    // Capabilities must not depend on publish result; refresh auth only.
    unawaited(_loadComposerCapabilities());
  }

  Future<void> _openCollection(BuildContext context) async {
    if (_composerCaps?.canCreateCollection != true) {
      _showSelectionSnack(
        _composerCaps?.reasonLabel('collection') ?? 'Недоступно',
      );
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CreateCollectionScreen()),
    );
    unawaited(_loadComposerCapabilities());
  }

  Future<void> _consumeForwardOutboxIfAny(String chatId) async {
    final data = await ForwardOutbox.tryTakeForChat(chatId);
    if (data == null) return;
    final raw = data.text ?? '';
    if (!ForwardPayload.isForwardText(raw)) {
      if (raw.isNotEmpty) {
        _ctrl.text = raw;
        _ctrl.selection =
            TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
      }
      return;
    }
    final payload = ForwardPayload.tryParse(raw);
    if (payload == null) return;
    await _stageForwardPayload(payload, data.fileUrls, chatId);
  }

  Future<void> _stageForwardPayload(
      ForwardPayload payload, List<String> fileUrls, String chatId) async {
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
      _ctrl.selection =
          TextSelection.fromPosition(TextPosition(offset: _ctrl.text.length));
    } else {
      _ctrl.clear();
    }

    if (sameChat) {
      setState(() {
        _forwardPackageAttached = true;
        _stagedForward = payload;
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
        _att.upload(attach,
            teamId: context.read<TeamCubit>().state.team.id, chatId: chatId);
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
    return p.endsWith('.jpg') ||
        p.endsWith('.jpeg') ||
        p.endsWith('.png') ||
        p.endsWith('.gif') ||
        p.endsWith('.webp');
  }

  String? _forwardComposerPreview() {
    final payload = _stagedForward;
    if (payload == null || payload.items.isEmpty) return null;
    final first = payload.items.first;
    final author =
        first.authorName.trim().isEmpty ? 'Сообщение' : first.authorName.trim();
    final text = first.text.trim();
    if (text.isNotEmpty) {
      final normalized = text.replaceAll(RegExp(r'\s+'), ' ');
      return '$author: $normalized';
    }
    if (first.files.isNotEmpty) {
      final fileName = first.files.first.name.trim();
      return '$author: ${fileName.isEmpty ? 'вложение' : fileName}';
    }
    return author;
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
        text: (m.text ?? '').trim(),
        files: files,
      ));
    }

    final teamId = context.read<TeamCubit>().state.team.id;
    final fromChatId = await _getChatIdForTeam(teamId);
    final caption = _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim();
    final payload =
        ForwardPayload(fromChatId: fromChatId, caption: caption, items: items);

    final uniqueFileUrls = fileUrls.where((u) => u.isNotEmpty).toSet().toList();
    final uniqueFileIds = fileIds.where((id) => id.isNotEmpty).toSet().toList();

    final target = await pickForwardTarget(context);
    if (target == null) return;

    if (target.chatId == fromChatId) {
      await _stageForwardPayload(payload, uniqueFileUrls, target.chatId);
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

      safeDebugLog(
          '[ChatTab] legacy file messages found count=${response.length}');

      // Загружаем файлы из chat_files
      for (final msg in response) {
        final fileId = msg['file_id'] as String;

        // Проверяем, есть ли уже в кэше
        final cachedFile = _globalCache.getFile(fileId);
        if (cachedFile != null) {
          safeDebugLog(
              '[ChatTab] legacy file already cached id=${maskDebugId(fileId)}');
          continue;
        }

        try {
          safeDebugLog(
              '[ChatTab] loading legacy file id=${maskDebugId(fileId)}');
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
            if ((chatFile.fileType).startsWith('image/') &&
                chatFile.fileUrl.isNotEmpty) {
              if (!_prefetchedImageUrls.contains(chatFile.fileUrl)) {
                _prefetchedImageUrls.add(chatFile.fileUrl);
                // ignore: unawaited_futures
                precacheImage(
                    CachedNetworkImageProvider(chatFile.fileUrl), context);
              }
            }
            safeDebugLog(
                '[ChatTab] legacy file cached file=${maskDebugId(fileId)} message=${maskDebugId(msg['id'])}');
          }
        } catch (e) {
          safeDebugLog(
              '[ChatTab] legacy file load failed id=${maskDebugId(fileId)} error=${e.runtimeType}');
        }
      }
    } catch (e) {
      safeDebugLog('[ChatTab] legacy files load failed: ${e.runtimeType}');
    }
  }

  // Удаляем старые методы загрузки файлов - теперь используем attachments из Message

  // Сохраняем файл в chat_files таблицу
  Future<ChatFile> _saveChatFileToDatabase(
      ChatFile chatFile, String userId) async {
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

      safeDebugLog('[ChatTab] uploaded file deleted id=${maskDebugId(fileId)}');
    } catch (e) {
      safeDebugLog(
          '[ChatTab] uploaded file delete failed id=${maskDebugId(fileId)} error=${e.runtimeType}');
    }
  }

  // Определяем, нужно ли показывать аватар для сообщения
  bool _shouldShowAvatar(
      List<Message> messages, int currentIndex, String? currentUserId) {
    if (currentIndex == 0)
      return true; // Первое сообщение всегда показывает аватар

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
    safeDebugLog('[ChatTab] open file action');
  }

  // Делимся файлом
  void _shareFile(ChatFile file) {
    // Реализация шаринга файла
    safeDebugLog('[ChatTab] share file action');
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
      safeDebugLog('[ChatTab] image attached');
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
    ca.ChatActions.showReactionPicker(
        context, (emoji) => _addReaction(messageId, emoji));
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
      isDismissible: true,
      enableDrag: true,
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
                  title: Text(p.title ?? '',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: p.subtitle != null ? Text(p.subtitle!) : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(
                        () => _pinsCtl.pins.removeWhere((e) => e.id == p.id)),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    if (p.type == PinType.message && p.refId != null)
                      _scrollToMessage(p.refId!);
                    if (p.type == PinType.assignment && p.refId != null) {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => BlocProvider.value(
                            value: context.read<TeamCubit>(),
                            child:
                                AssignmentDetailsScreen(assignmentId: p.refId!),
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(pin.title ?? '')));
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
  void _onPropose(String title, String description, String? link, String? due,
      List<Map<String, String>> attachments) async {
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
    safeDebugLog('[ChatTab] assignment unpin ignored');
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
