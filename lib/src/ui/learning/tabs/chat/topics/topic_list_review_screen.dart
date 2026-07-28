import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/chat_group_actions_repository.dart';
import '../models/chat_group_actions.dart';
import 'pdfrx_topic_pdf_page_renderer.dart';
import 'topic_image_preprocess.dart';
import 'topic_list_models.dart';
import 'topic_list_parser.dart';
import 'topic_list_review_controller.dart';
import 'topic_ocr_adapter.dart';
import 'topic_ocr_ui_helpers.dart';

/// Review/edit topic list before publishing to chat.
class TopicListReviewScreen extends StatefulWidget {
  const TopicListReviewScreen({
    super.key,
    required this.chatId,
    required this.title,
    this.description = '',
    this.deadlineAt,
    this.completionDeadlineAt,
    this.allowChange = true,
    this.showResultsToAll = true,
    this.sourceFileId,
    this.sourceLocalPath,
    this.sourceBytes,
    this.sourceFileName,
    this.initialOptions = const [],
    this.parseResult,
    this.ocrAdapter,
    this.repository,
  });

  final String chatId;
  final String title;
  final String description;
  final DateTime? deadlineAt;
  final DateTime? completionDeadlineAt;
  final bool allowChange;
  final bool showResultsToAll;
  final String? sourceFileId;
  final String? sourceLocalPath;
  final Uint8List? sourceBytes;
  final String? sourceFileName;
  final List<TopicOptionDraft> initialOptions;
  final TopicParseResult? parseResult;
  final TopicOcrAdapter? ocrAdapter;
  final ChatGroupActionsRepository? repository;

  @override
  State<TopicListReviewScreen> createState() => _TopicListReviewScreenState();
}

class _TopicListReviewScreenState extends State<TopicListReviewScreen> {
  late final ChatGroupActionsRepository _repo =
      widget.repository ?? ChatGroupActionsRepository();
  late final TopicListReviewController _controller;
  late final TopicListParser _parser;
  late final TopicOcrAdapter _ocrAdapter;
  late final bool _ownsOcrAdapter;
  TopicParseResult? _parseResult;
  int? _excelColumnIndex;
  String? _excelSheetName;
  bool _publishing = false;
  bool _reparsing = false;
  String? _reparseProgress;
  Uint8List? _workingSourceBytes;
  final _imagePreprocessor = createDefaultTopicImagePreprocessor();

  @override
  void initState() {
    super.initState();
    _parseResult = widget.parseResult;
    _excelColumnIndex = widget.parseResult?.suggestedExcelColumn;
    _excelSheetName = widget.parseResult?.selectedExcelSheet;
    _workingSourceBytes = widget.sourceBytes;
    final provided = widget.ocrAdapter;
    _ownsOcrAdapter = provided == null;
    _ocrAdapter = provided ?? createDefaultTopicOcrAdapter();
    _parser = TopicListParser(
      ocrAdapter: _ocrAdapter,
      pdfPageRenderer: createDefaultTopicPdfPageRenderer(),
    );
    _controller = TopicListReviewController(
      initial: [
        for (final opt in widget.initialOptions)
          TopicDraft(title: opt.title, capacity: opt.capacity),
      ],
    );
  }

  @override
  void dispose() {
    if (_ownsOcrAdapter) {
      _ocrAdapter.dispose();
    }
    super.dispose();
  }

  bool get _hasExcelHeaders {
    final headers = _parseResult?.excelHeaders;
    return headers != null && headers.isNotEmpty;
  }

  bool get _hasExcelSheets {
    final sheets = _parseResult?.excelSheetNames;
    return sheets != null && sheets.length > 1;
  }

  bool get _canReparseImage =>
      widget.sourceBytes != null &&
      (_parseResult?.kind == TopicParseSourceKind.image ||
          _parseResult?.kind == TopicParseSourceKind.pdf);

  Future<void> _reparseExcel({
    int? columnIndex,
    String? sheetName,
  }) async {
    final bytes = widget.sourceBytes;
    final name = widget.sourceFileName ?? _parseResult?.sourceName;
    if (bytes == null || name == null) return;

    final nextColumn = columnIndex ?? _excelColumnIndex;
    final nextSheet = sheetName ?? _excelSheetName;

    setState(() => _reparsing = true);
    try {
      final result = await _parser.parseBytes(
        bytes: bytes,
        sourceName: name,
        excelColumnIndex: nextColumn,
        excelSheetName: nextSheet,
        ocr: widget.ocrAdapter,
      );
      if (!mounted) return;
      if (result.isSuccess) {
        setState(() {
          _parseResult = result;
          _excelColumnIndex = result.suggestedExcelColumn ?? nextColumn;
          _excelSheetName = result.selectedExcelSheet ?? nextSheet;
        });
        _controller.applyParseResult(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.error ?? 'Не удалось переразобрать Excel'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _reparsing = false);
    }
  }

  Future<void> _reparseWithOcr({bool retry = false}) async {
    var bytes = _workingSourceBytes ?? widget.sourceBytes;
    final name = widget.sourceFileName ?? _parseResult?.sourceName;
    if (bytes == null || name == null) return;

    setState(() {
      _reparsing = true;
      _reparseProgress = 'Распознавание текста…';
    });
    try {
      if (_parseResult?.kind == TopicParseSourceKind.image && !retry) {
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
        _workingSourceBytes = prepared;
      }

      List<int>? pdfPages;
      if (_parseResult?.kind == TopicParseSourceKind.pdf) {
        setState(() => _reparseProgress = 'Подготовка страниц PDF…');
        final pageCount = await _parser.pdfPageCount(bytes: bytes);
        if (!mounted) return;
        pdfPages = await showTopicPdfPagePicker(
          context: context,
          pageCount: pageCount,
        );
        if (pdfPages == null || !mounted) return;
        setState(() => _reparseProgress = 'Распознавание текста…');
      }

      final result = await _parser.parseBytes(
        bytes: bytes,
        sourceName: name,
        excelColumnIndex: _excelColumnIndex,
        ocr: widget.ocrAdapter,
        pdfOcrPageIndices: pdfPages,
        pdfPageRenderer: createDefaultTopicPdfPageRenderer(),
      );
      if (!mounted) return;
      if (result.isSuccess) {
        setState(() => _parseResult = result);
        _controller.applyParseResult(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.error ??
                  'OCR недоступен — введите темы вручную или выберите другой файл.',
            ),
            action: SnackBarAction(
              label: 'Повторить',
              onPressed: () => _reparseWithOcr(retry: true),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _reparsing = false;
          _reparseProgress = null;
        });
      }
    }
  }

  Future<void> _showExcelSheetPicker() async {
    final sheets = _parseResult?.excelSheetNames;
    if (sheets == null || sheets.length < 2) return;

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) {
        var value = _excelSheetName ?? sheets.first;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Лист Excel'),
              content: DropdownButtonFormField<String>(
                initialValue: sheets.contains(value) ? value : sheets.first,
                items: [
                  for (final sheet in sheets)
                    DropdownMenuItem(value: sheet, child: Text(sheet)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setDialogState(() => value = v);
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, value),
                  child: const Text('Применить'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected == null || selected == _excelSheetName) return;
    await _reparseExcel(sheetName: selected);
  }

  Future<void> _showExcelColumnPicker() async {
    final headers = _parseResult?.excelHeaders;
    if (headers == null || headers.isEmpty) return;

    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) {
        var value = _excelColumnIndex ?? 0;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Столбец с темами'),
              content: DropdownButtonFormField<int>(
                initialValue: value.clamp(0, headers.length - 1),
                items: [
                  for (var i = 0; i < headers.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        headers[i].isEmpty ? 'Столбец ${i + 1}' : headers[i],
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setDialogState(() => value = v);
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, value),
                  child: const Text('Применить'),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected == null || selected == _excelColumnIndex) return;
    await _reparseExcel(columnIndex: selected);
  }

  void _addOption() {
    setState(() => _controller.add(title: 'Тема ${_controller.length + 1}'));
  }

  void _dedupe() {
    setState(() => _controller.dedupe());
  }

  Future<void> _editOption(int index) async {
    final topic = _controller.topics[index];
    final ctrl = TextEditingController(text: topic.title);
    final capCtrl = TextEditingController(text: topic.capacity.toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Редактировать тему'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            TextField(
              controller: capCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Мест'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final title = ctrl.text.trim();
    if (title.isEmpty) return;
    final capacity = int.tryParse(capCtrl.text.trim()) ?? 1;
    setState(() {
      _controller.editAt(
        index,
        title: title,
        capacity: capacity.clamp(1, 999),
      );
    });
  }

  void _deleteOption(int index) {
    setState(() => _controller.removeAt(index));
  }

  void _mergeWithNext(int index) {
    setState(() => _controller.mergeAdjacent(index));
  }

  void _splitLine(int index) {
    setState(() => _controller.splitLine(index));
  }

  Future<void> _publish() async {
    if (_controller.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавьте хотя бы одну тему')),
      );
      return;
    }

    if (_controller.length > topicListMaxTopics) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Не более $topicListMaxTopics тем в одном выборе'),
        ),
      );
      return;
    }

    final options = publishJsonToOptionDrafts(_controller.toPublishJson())
        .where((e) => e.title.isNotEmpty)
        .toList();

    if (options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Добавьте хотя бы одну тему')),
      );
      return;
    }

    setState(() => _publishing = true);
    try {
      await _repo.publishTopicSelectionForChat(
        chatId: widget.chatId,
        title: widget.title,
        description: widget.description,
        deadlineAt: widget.deadlineAt,
        completionDeadlineAt: null,
        allowChange: widget.allowChange,
        showResultsToAll: widget.showResultsToAll,
        sourceFileId: widget.sourceFileId,
        options: options,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось опубликовать выбор темы')),
      );
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final topics = _controller.topics;
    final warnings = _parseResult?.warnings ?? const <String>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Проверка списка тем'),
        actions: [
          if (_hasExcelSheets)
            IconButton(
              tooltip: 'Лист Excel',
              onPressed: _reparsing ? null : _showExcelSheetPicker,
              icon: const Icon(Icons.tab_outlined),
            ),
          if (_hasExcelHeaders)
            IconButton(
              tooltip: 'Столбец Excel',
              onPressed: _reparsing ? null : _showExcelColumnPicker,
              icon: const Icon(Icons.table_chart_outlined),
            ),
          TextButton(
            onPressed: _dedupe,
            child: const Text('Убрать дубли'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_reparsing) ...[
            const LinearProgressIndicator(minHeight: 2),
            if (_reparseProgress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  _reparseProgress!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
          if (warnings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                warnings.join('\n'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.orange.shade800,
                    ),
              ),
            ),
          if (_controller.length >= topicListMaxTopics)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Достигнут лимит $topicListMaxTopics тем',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.orange.shade800,
                    ),
              ),
            ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: topics.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  var target = newIndex;
                  if (target > oldIndex) target -= 1;
                  _controller.reorder(oldIndex, target);
                });
              },
              itemBuilder: (context, index) {
                final opt = topics[index];
                return Card(
                  key: ValueKey('topic_${index}_${opt.title}'),
                  child: ListTile(
                    leading: ReorderableDragStartListener(
                      index: index,
                      child: const Icon(Icons.drag_handle),
                    ),
                    title: Text(opt.title),
                    subtitle: Text('Мест: ${opt.capacity}'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        switch (action) {
                          case 'edit':
                            _editOption(index);
                            break;
                          case 'merge':
                            _mergeWithNext(index);
                            break;
                          case 'split':
                            _splitLine(index);
                            break;
                          case 'delete':
                            _deleteOption(index);
                            break;
                          case 'ocr':
                            if (_canReparseImage) {
                              _reparseWithOcr();
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Повторный OCR доступен только для исходного изображения или PDF',
                                  ),
                                ),
                              );
                            }
                            break;
                          case 'excel_sheet':
                            if (_hasExcelSheets) {
                              _showExcelSheetPicker();
                            }
                            break;
                          case 'excel':
                            if (_hasExcelHeaders) {
                              _showExcelColumnPicker();
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Выбор столбца доступен только для Excel',
                                  ),
                                ),
                              );
                            }
                            break;
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                            value: 'edit', child: Text('Изменить')),
                        const PopupMenuItem(
                          value: 'merge',
                          child: Text('Объединить со следующей'),
                        ),
                        const PopupMenuItem(
                          value: 'split',
                          child: Text('Разделить строку'),
                        ),
                        const PopupMenuItem(
                            value: 'delete', child: Text('Удалить')),
                        if (_hasExcelSheets)
                          const PopupMenuItem(
                            value: 'excel_sheet',
                            child: Text('Выбрать лист Excel'),
                          ),
                        if (_hasExcelHeaders)
                          const PopupMenuItem(
                            value: 'excel',
                            child: Text('Перевыбрать столбец Excel'),
                          ),
                        if (_canReparseImage)
                          const PopupMenuItem(
                            value: 'ocr',
                            child: Text('Повторить OCR'),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: _controller.length >= topicListMaxTopics
                        ? null
                        : _addOption,
                    icon: const Icon(Icons.add),
                    label: const Text('Добавить тему'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _publishing ? null : _publish,
                    child: _publishing
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Опубликовать в чат'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
