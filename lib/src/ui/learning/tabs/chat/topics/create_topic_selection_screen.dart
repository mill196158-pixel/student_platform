import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../../services/file_service.dart';
import '../../../../common/keyboard_dismiss_scope.dart';
import '../../../models/chat_file.dart';
import '../data/chat_repository.dart';
import '../models/chat_group_actions.dart';
import 'mlkit_topic_ocr_adapter.dart';
import 'pdfrx_topic_pdf_page_renderer.dart';
import 'topic_extraction_service.dart';
import 'topic_image_preprocess.dart';
import 'topic_list_models.dart';
import 'topic_list_parser.dart';
import 'topic_list_review_screen.dart';
import 'topic_ocr_ui_helpers.dart';

/// Form to start a topic selection; continues to review/publish flow.
class CreateTopicSelectionScreen extends StatefulWidget {
  const CreateTopicSelectionScreen({
    super.key,
    required this.chatId,
    this.repository,
  });

  final String chatId;
  final dynamic repository;

  @override
  State<CreateTopicSelectionScreen> createState() =>
      _CreateTopicSelectionScreenState();
}

class _CreateTopicSelectionScreenState
    extends State<CreateTopicSelectionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _fileService = FileService();
  late final ChatRepository _chatRepo = ChatRepository(
    supabase: Supabase.instance.client,
    fileService: _fileService,
  );
  late final TopicListParser _parser = TopicListParser(
    ocrAdapter: _ocrAdapter(),
    pdfPageRenderer: createDefaultTopicPdfPageRenderer(),
  );
  final _imagePreprocessor = createDefaultTopicImagePreprocessor();

  DateTime? _deadline;
  bool _allowChange = true;
  bool _showResultsToAll = true;
  String? _sourceFileName;
  String? _sourceFilePath;
  Uint8List? _sourceFileBytes;
  String? _sourceFileId;
  String? _uploadWarning;
  bool _parsing = false;
  String? _parseProgress;
  Future<void>? _sourceUploadFuture;
  int _sourceGeneration = 0;
  TopicOcrAdapter? _ownedOcrAdapter;

  static const _allowedExtensions = [
    'xlsx',
    'xlsm',
    'xltx',
    'xltm',
    'docx',
    'pdf',
    'png',
    'jpg',
    'jpeg',
    'webp',
    'bmp',
    'gif',
    'heic',
  ];

  @override
  void initState() {
    super.initState();
    _titleCtrl.addListener(_onChanged);
    _descCtrl.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    final ocr = _ownedOcrAdapter;
    _ownedOcrAdapter = null;
    if (ocr != null) {
      // Fire-and-forget native cleanup.
      ocr.dispose();
    }
    super.dispose();
  }

  TopicOcrAdapter _ocrAdapter() {
    return _ownedOcrAdapter ??= createDefaultTopicOcrAdapter();
  }

  TopicExtractionService get _extraction =>
      LocalTopicExtractionService(parser: _parser);

  Future<void> _pickDeadline() async {
    KeyboardDismissScope.unfocus(context);
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
      initialDate: _deadline ?? now,
      helpText: 'Выбрать до',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
        _deadline ?? now.add(const Duration(hours: 2)),
      ),
      helpText: 'Выбрать до',
      cancelText: 'Отмена',
      confirmText: 'Готово',
    );
    if (time == null || !mounted) return;
    setState(() {
      _deadline = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time.hour,
        time.minute,
      );
    });
  }

  void _setQuickDeadline(int daysFromNow) {
    final now = DateTime.now();
    final base = now.add(Duration(days: daysFromNow));
    setState(() {
      _deadline = DateTime(base.year, base.month, base.day, 23, 59);
    });
  }

  bool _isDeadlineInDays(int days) {
    final d = _deadline;
    if (d == null) return false;
    final target = DateTime.now().add(Duration(days: days));
    return d.year == target.year &&
        d.month == target.month &&
        d.day == target.day;
  }

  Future<void> _pickSourceFile() async {
    KeyboardDismissScope.unfocus(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: _allowedExtensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty || !mounted) return;

    final picked = result.files.first;
    final name = picked.name;
    Uint8List? bytes = picked.bytes;
    final path = picked.path;

    if (bytes == null && path != null) {
      try {
        bytes = await File(path).readAsBytes();
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось прочитать выбранный файл')),
        );
        return;
      }
    }

    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось прочитать выбранный файл')),
      );
      return;
    }

    _sourceGeneration += 1;
    final generation = _sourceGeneration;
    setState(() {
      _sourceFileName = name;
      _sourceFilePath = path;
      _sourceFileBytes = bytes;
      _sourceFileId = null;
      _uploadWarning = null;
    });

    _sourceUploadFuture = _tryUploadSourceFile(
      path: path,
      fileName: name,
      generation: generation,
    );
  }

  Future<void> _pickImageSource(ImageSource source) async {
    KeyboardDismissScope.unfocus(context);
    final file = await _fileService.pickImage(source: source);
    if (file == null || !mounted) return;

    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось прочитать выбранное фото')),
      );
      return;
    }

    if (bytes.length > topicListMaxFileBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Файл слишком большой. Максимум '
            '${topicListMaxFileBytes ~/ (1024 * 1024)} МБ.',
          ),
        ),
      );
      return;
    }

    final name = file.path.split('/').last;
    _sourceGeneration += 1;
    final generation = _sourceGeneration;
    setState(() {
      _sourceFileName =
          name.endsWith('.jpg') || name.endsWith('.png') ? name : '$name.jpg';
      _sourceFilePath = file.path;
      _sourceFileBytes = bytes;
      _sourceFileId = null;
      _uploadWarning = null;
    });

    _sourceUploadFuture = _tryUploadSourceFile(
      path: file.path,
      fileName: _sourceFileName!,
      generation: generation,
    );
  }

  Future<String?> _ensureSourceUploaded() async {
    final pending = _sourceUploadFuture;
    if (pending != null) {
      await pending;
    }
    return _sourceFileId;
  }

  Future<bool> _confirmPublishWithoutSourceAttachment() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Исходный файл не загружен'),
        content: const Text(
          'Файл разобран локально, но вложение в чат ещё не готово. '
          'Опубликовать выбор темы без исходного файла?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Подождать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Без вложения'),
          ),
        ],
      ),
    );
    return proceed == true;
  }

  Future<void> _showImagePickOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Галерея'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImageSource(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Камера'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImageSource(ImageSource.camera);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _tryUploadSourceFile({
    String? path,
    required String fileName,
    required int generation,
  }) async {
    if (path == null || path.isEmpty) {
      if (mounted && generation == _sourceGeneration) {
        setState(() {
          _uploadWarning =
              'Файл сохранён локально — загрузка в чат недоступна без пути.';
        });
      }
      return;
    }

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        if (mounted && generation == _sourceGeneration) {
          setState(() {
            _uploadWarning =
                'Войдите в аккаунт, чтобы прикрепить исходный файл к чату.';
          });
        }
        return;
      }

      final upload = await _fileService.uploadFile(
        file: File(path),
        chatId: widget.chatId,
        customFileName: fileName,
      );
      if (generation != _sourceGeneration) return;
      if (!upload.success ||
          upload.fileKey == null ||
          upload.fileUrl == null ||
          upload.fileName == null) {
        if (mounted && generation == _sourceGeneration) {
          setState(() {
            _uploadWarning =
                'Не удалось загрузить файл в чат — список всё равно можно разобрать локально.';
          });
        }
        return;
      }

      final chatFile = ChatFile(
        id: '',
        chatId: widget.chatId,
        messageId: null,
        fileName: upload.fileName!,
        fileKey: upload.fileKey!,
        fileUrl: upload.fileUrl!,
        fileType: upload.fileType ?? 'application/octet-stream',
        fileSize: upload.fileSize ?? 0,
        uploadedBy: userId,
        uploadedAt: DateTime.now(),
      );
      final id = await _chatRepo.saveChatFile(chatFile, userId);
      if (!mounted || generation != _sourceGeneration) return;
      setState(() {
        _sourceFileId = id;
        _uploadWarning = null;
      });
    } catch (_) {
      if (!mounted || generation != _sourceGeneration) return;
      setState(() {
        _uploadWarning =
            'Не удалось загрузить файл в чат — список всё равно можно разобрать локально.';
      });
    }
  }

  Future<void> _openReview({
    required List<TopicOptionDraft> initialOptions,
    TopicParseResult? parseResult,
  }) async {
    KeyboardDismissScope.unfocus(context);
    final sourceId = await _ensureSourceUploaded();
    if (!mounted) return;

    if (_sourceFileBytes != null && sourceId == null) {
      final ok = await _confirmPublishWithoutSourceAttachment();
      if (!ok || !mounted) return;
    }

    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TopicListReviewScreen(
          chatId: widget.chatId,
          title: _titleCtrl.text.trim(),
          description: _descCtrl.text.trim(),
          deadlineAt: _deadline,
          completionDeadlineAt: null,
          allowChange: _allowChange,
          showResultsToAll: _showResultsToAll,
          sourceFileId: sourceId,
          sourceLocalPath: _sourceFilePath,
          sourceBytes: _sourceFileBytes,
          sourceFileName: _sourceFileName,
          initialOptions: initialOptions,
          parseResult: parseResult,
          ocrAdapter: _ocrAdapter(),
        ),
      ),
    );
    if (published == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выбор темы опубликован в чат')),
      );
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _continueManual() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    KeyboardDismissScope.unfocus(context);
    HapticFeedback.lightImpact();
    await _openReview(initialOptions: const []);
  }

  Future<void> _continueFromParse({bool retry = false}) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_sourceFileBytes == null || _sourceFileName == null) {
      _continueManual();
      return;
    }
    KeyboardDismissScope.unfocus(context);
    HapticFeedback.lightImpact();

    setState(() {
      _parsing = true;
      _parseProgress = 'Разбор файла…';
    });
    try {
      var bytes = _sourceFileBytes!;
      final name = _sourceFileName!;
      final kind = _kindFromFileName(name);

      if (kind == TopicParseSourceKind.image && !retry) {
        final prepared = await showTopicImagePreprocessSheet(
          context: context,
          bytes: bytes,
          onRotate: (current, degrees) => _imagePreprocessor.rotate(
            bytes: current,
            degrees: degrees,
          ),
          onCrop: (current) => _imagePreprocessor.crop(bytes: current),
        );
        if (prepared == null || !mounted) return;
        bytes = prepared;
        setState(() => _sourceFileBytes = prepared);
      }

      var result = await _extraction.extractFromBytes(
        bytes: bytes,
        sourceName: name,
        ocr: _ocrAdapter(),
      );

      if (!mounted) return;

      if (result.needsOcr && result.kind == TopicParseSourceKind.pdf) {
        setState(() => _parseProgress = 'Подготовка страниц PDF…');
        final pageCount = await _parser.pdfPageCount(bytes: bytes);
        if (!mounted) return;

        final selectedPages = await showTopicPdfPagePicker(
          context: context,
          pageCount: pageCount,
        );
        if (selectedPages == null || !mounted) return;

        setState(() => _parseProgress = 'Распознавание текста…');
        result = await _parser.parseBytes(
          bytes: bytes,
          sourceName: name,
          ocr: _ocrAdapter(),
          pdfOcrPageIndices: selectedPages,
          pdfPageRenderer: createDefaultTopicPdfPageRenderer(),
        );
        if (!mounted) return;
      }

      if (result.isSuccess) {
        await _openReview(
          initialOptions: result.toOptionDrafts(),
          parseResult: result,
        );
        return;
      }

      final message = result.error ??
          (result.needsOcr
              ? 'В файле не найден текст — попробуйте фото списка или введите темы вручную.'
              : 'Не удалось разобрать файл.');

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(
            label: 'Повторить',
            onPressed: () => _continueFromParse(retry: true),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка разбора: $e'),
          action: SnackBarAction(
            label: 'Повторить',
            onPressed: () => _continueFromParse(retry: true),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _parsing = false;
          _parseProgress = null;
        });
      }
    }
  }

  TopicParseSourceKind _kindFromFileName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return TopicParseSourceKind.pdf;
    for (final ext in [
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
      '.bmp',
      '.gif',
      '.heic'
    ]) {
      if (lower.endsWith(ext)) return TopicParseSourceKind.image;
    }
    return TopicParseSourceKind.manual;
  }

  String _fmt(DateTime? dt) {
    if (dt == null) return 'Не задан';
    return '${dt.day.toString().padLeft(2, '0')}.'
        '${dt.month.toString().padLeft(2, '0')}.'
        '${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  bool get _canContinue => !_parsing && _titleCtrl.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final titleLen = _titleCtrl.text.trim().length;
    final hasSource = _sourceFileName != null;

    return Scaffold(
      backgroundColor: cs.surface,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: KeyboardDismissScope(
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: IconButton(
                            tooltip: 'Назад',
                            onPressed: _parsing
                                ? null
                                : () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                        const _TopicHeroHeader(),
                        const SizedBox(height: 20),
                        const _SectionLabel(
                          icon: Icons.edit_note_rounded,
                          label: 'О выборе',
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _titleCtrl,
                          autofocus: true,
                          textInputAction: TextInputAction.next,
                          textCapitalization: TextCapitalization.sentences,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                          decoration: _fieldDecoration(
                            label: 'Название',
                            hint: 'Например: Выбрать тему доклада',
                            icon: Icons.title_rounded,
                            suffix: titleLen > 0
                                ? Text(
                                    '$titleLen',
                                    style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                : null,
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Укажите название'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _descCtrl,
                          minLines: 2,
                          maxLines: 4,
                          textInputAction: TextInputAction.done,
                          textCapitalization: TextCapitalization.sentences,
                          onEditingComplete: () =>
                              KeyboardDismissScope.unfocus(context),
                          style: const TextStyle(color: Colors.black87),
                          decoration: _fieldDecoration(
                            label: 'Краткое описание',
                            hint: 'Необязательно',
                            icon: Icons.notes_rounded,
                            alignLabelWithHint: true,
                          ),
                        ),
                        const SizedBox(height: 20),
                        _SectionLabel(
                          icon: Icons.event_available_rounded,
                          label: 'Выбрать до',
                          trailing: _deadline == null
                              ? 'Необязательно'
                              : _fmt(_deadline),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _QuickChip(
                              label: 'Завтра',
                              selected: _isDeadlineInDays(1),
                              onTap: () => _setQuickDeadline(1),
                            ),
                            _QuickChip(
                              label: '+3 дня',
                              selected: _isDeadlineInDays(3),
                              onTap: () => _setQuickDeadline(3),
                            ),
                            _QuickChip(
                              label: 'Через неделю',
                              selected: _isDeadlineInDays(7),
                              onTap: () => _setQuickDeadline(7),
                            ),
                            _QuickChip(
                              label: 'Календарь',
                              icon: Icons.calendar_month_rounded,
                              selected: _deadline != null &&
                                  !_isDeadlineInDays(1) &&
                                  !_isDeadlineInDays(3) &&
                                  !_isDeadlineInDays(7),
                              onTap: _pickDeadline,
                            ),
                            if (_deadline != null)
                              _QuickChip(
                                label: 'Сбросить',
                                icon: Icons.close_rounded,
                                selected: false,
                                tone: _ChipTone.muted,
                                onTap: () => setState(() => _deadline = null),
                              ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        const _SectionLabel(
                          icon: Icons.tune_rounded,
                          label: 'Правила',
                        ),
                        const SizedBox(height: 10),
                        _SoftSwitchTile(
                          title: 'Разрешить смену темы',
                          subtitle: 'Пока срок не истёк',
                          value: _allowChange,
                          onChanged: (v) => setState(() => _allowChange = v),
                        ),
                        const SizedBox(height: 8),
                        _SoftSwitchTile(
                          title: 'Показывать, кто выбрал',
                          subtitle: 'Иначе имена видят только организаторы',
                          value: _showResultsToAll,
                          onChanged: (v) =>
                              setState(() => _showResultsToAll = v),
                        ),
                        const SizedBox(height: 20),
                        const _SectionLabel(
                          icon: Icons.library_books_outlined,
                          label: 'Источник тем',
                          trailing: 'Файл или вручную',
                        ),
                        const SizedBox(height: 10),
                        _SoftActionTile(
                          icon: Icons.attach_file_rounded,
                          title: _sourceFileName ?? 'Excel, Word, PDF или фото',
                          subtitle: hasSource
                              ? 'Можно заменить другим файлом'
                              : 'Список тем подставится в проверку',
                          onTap: _parsing ? null : _pickSourceFile,
                        ),
                        const SizedBox(height: 8),
                        _SoftActionTile(
                          icon: Icons.photo_camera_outlined,
                          title: 'Сфотографировать список',
                          subtitle: 'Галерея или камера',
                          onTap: _parsing ? null : _showImagePickOptions,
                        ),
                        if (hasSource) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                            decoration: BoxDecoration(
                              color: cs.surface,
                              borderRadius: BorderRadius.circular(16),
                              border:
                                  Border.all(color: const Color(0xFFE1E5EF)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.description_outlined,
                                    color: cs.primary, size: 20),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _sourceFileName!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.black87,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Убрать файл',
                                  onPressed: _parsing
                                      ? null
                                      : () {
                                          _sourceGeneration += 1;
                                          setState(() {
                                            _sourceFileName = null;
                                            _sourceFilePath = null;
                                            _sourceFileBytes = null;
                                            _sourceFileId = null;
                                            _uploadWarning = null;
                                            _sourceUploadFuture = null;
                                          });
                                        },
                                  icon:
                                      const Icon(Icons.close_rounded, size: 20),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (_parseProgress != null) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Text(_parseProgress!)),
                            ],
                          ),
                        ],
                        if (_uploadWarning != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _uploadWarning!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.error),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: cs.primary.withValues(alpha: 0.10),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.tips_and_updates_outlined,
                                  size: 18, color: cs.primary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Распознанный файл заполнит список тем '
                                  'на следующем шаге — вы сможете править '
                                  'перед публикацией.',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(
              padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + viewInsets.bottom),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                  top: BorderSide(
                    color: Colors.black.withValues(alpha: 0.06),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: !_canContinue
                        ? null
                        : (hasSource ? _continueFromParse : _continueManual),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    icon: _parsing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            hasSource
                                ? Icons.document_scanner_outlined
                                : Icons.edit_note_rounded,
                          ),
                    label: Text(
                      _parsing
                          ? (_parseProgress ?? 'Разбор…')
                          : (hasSource
                              ? 'Распознать и проверить'
                              : 'Ввести темы вручную'),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (hasSource) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _parsing ? null : _continueManual,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text('Ввести темы вручную'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration({
    required String label,
    required String hint,
    required IconData icon,
    Widget? suffix,
    bool alignLabelWithHint = false,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: alignLabelWithHint,
      prefixIcon: Icon(icon),
      suffixIcon: suffix == null
          ? null
          : (suffix is IconButton
              ? suffix
              : Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    widthFactor: 1,
                    child: suffix,
                  ),
                )),
      filled: true,
      fillColor: const Color(0xFFF6F7FB),
      labelStyle: const TextStyle(color: Colors.black54),
      floatingLabelStyle: const TextStyle(
        color: Colors.black87,
        fontWeight: FontWeight.w700,
      ),
      hintStyle: TextStyle(color: Colors.black.withValues(alpha: 0.35)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE1E5EF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.black87, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE53935)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFFE53935), width: 1.4),
      ),
    );
  }
}

class _TopicHeroHeader extends StatelessWidget {
  const _TopicHeroHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  cs.primary.withValues(alpha: 0.14),
                  cs.primaryContainer.withValues(alpha: 0.55),
                  const Color(0xFFF6F7FB),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          Positioned(
            right: -24,
            top: -28,
            child: _GlowBlob(
              diameter: 110,
              color: cs.primary.withValues(alpha: 0.16),
            ),
          ),
          Positioned(
            left: -18,
            bottom: -34,
            child: _GlowBlob(
              diameter: 96,
              color: Colors.white.withValues(alpha: 0.65),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.topic_outlined,
                    color: cs.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Выбор темы',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Один срок и список тем — из файла или вручную',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.black.withValues(alpha: 0.62),
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowBlob extends StatelessWidget {
  final double diameter;
  final Color color;
  const _GlowBlob({required this.diameter, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? trailing;
  const _SectionLabel({
    required this.icon,
    required this.label,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: Colors.black87,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.black45,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

enum _ChipTone { accent, muted }

class _QuickChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  final _ChipTone tone;

  const _QuickChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.tone = _ChipTone.accent,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMuted = tone == _ChipTone.muted;
    final bg = selected
        ? cs.primary
        : (isMuted
            ? Colors.black.withValues(alpha: 0.05)
            : const Color(0xFFF6F7FB));
    final fg =
        selected ? cs.onPrimary : (isMuted ? Colors.black54 : Colors.black87);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? Colors.transparent : const Color(0xFFE1E5EF),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoftActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _SoftActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: const Color(0xFFF6F7FB),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: const Border.fromBorderSide(
              BorderSide(color: Color(0xFFE1E5EF)),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: cs.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.add_rounded, color: cs.primary.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SoftSwitchTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SoftSwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE1E5EF)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
