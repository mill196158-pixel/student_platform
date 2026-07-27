import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../../services/file_service.dart';
import '../../../models/chat_file.dart';
import '../data/chat_repository.dart';
import '../models/chat_group_actions.dart';
import 'mlkit_topic_ocr_adapter.dart';
import 'pdfrx_topic_pdf_page_renderer.dart';
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
  DateTime? _completionDeadline;
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

  Future<void> _pickDeadline({required bool completion}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
      initialDate: now,
      helpText: completion ? 'Срок выполнения' : 'Дедлайн выбора',
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 2))),
    );
    if (time == null || !mounted) return;
    final value = DateTime(
      picked.year,
      picked.month,
      picked.day,
      time.hour,
      time.minute,
    );
    setState(() {
      if (completion) {
        _completionDeadline = value;
      } else {
        _deadline = value;
      }
    });
  }

  Future<void> _pickSourceFile() async {
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
          completionDeadlineAt: _completionDeadline,
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
    if (!_formKey.currentState!.validate()) return;
    await _openReview(initialOptions: const []);
  }

  Future<void> _continueFromParse({bool retry = false}) async {
    if (!_formKey.currentState!.validate()) return;
    if (_sourceFileBytes == null || _sourceFileName == null) {
      _continueManual();
      return;
    }

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

      var result = await _parser.parseBytes(
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Выбор темы')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                labelText: 'Название',
                hintText: 'Например: Темы докладов',
              ),
              validator: (v) =>
                  (v ?? '').trim().isEmpty ? 'Укажите название' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _descCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Описание',
                hintText: 'Необязательно',
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Дедлайн выбора'),
              subtitle: Text(_fmt(_deadline)),
              trailing: const Icon(Icons.event_outlined),
              onTap: () => _pickDeadline(completion: false),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Срок выполнения (необязательно)'),
              subtitle: Text(_fmt(_completionDeadline)),
              trailing: const Icon(Icons.event_available_outlined),
              onTap: () => _pickDeadline(completion: true),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Разрешить смену темы'),
              value: _allowChange,
              onChanged: (v) => setState(() => _allowChange = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Показывать результаты всем'),
              subtitle: const Text(
                'Иначе только организаторы видят, кто что выбрал',
              ),
              value: _showResultsToAll,
              onChanged: (v) => setState(() => _showResultsToAll = v),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pickSourceFile,
              icon: const Icon(Icons.attach_file_outlined),
              label: Text(
                _sourceFileName ?? 'Исходный файл (Excel, Word, PDF, фото)',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _parsing ? null : _showImagePickOptions,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Сфотографировать или выбрать из галереи'),
            ),
            if (_parseProgress != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
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
                style:
                    theme.textTheme.bodySmall?.copyWith(color: Colors.orange),
              ),
            ],
            if (_sourceFileId != null) ...[
              const SizedBox(height: 4),
              Text(
                'Файл загружен в чат',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.green),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              'Дальше — проверка списка тем перед публикацией в чат.',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
            ),
            const SizedBox(height: 16),
            if (_sourceFileName != null) ...[
              FilledButton(
                onPressed: _parsing ? null : _continueFromParse,
                child: _parsing
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Разобрать файл и проверить'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _parsing ? null : _continueManual,
                child: const Text('Добавить темы вручную'),
              ),
            ] else
              FilledButton(
                onPressed: _continueManual,
                child: const Text('Добавить темы вручную'),
              ),
          ],
        ),
      ),
    );
  }
}
