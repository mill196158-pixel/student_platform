// =============================
// FILE: lib/src/ui/learning/tabs/chat/topics/topic_list_review_screen.dart
// =============================
//
// Stage 13.12 continuation — modernized draft/OCR review screen, matching
// the New-Assignment-style hero header + soft cards used by
// `create_topic_selection_screen.dart`. Replaces the old grey-AppBar table
// look with a hero header, topic count + search, drag reorder, multi-select
// bulk delete, undo-delete, duplicate/empty-row warnings, and bottom-sheet
// (never AlertDialog) inline editing — while keeping every Stage 13.9 OCR/
// Excel re-parse capability (sheet/column pickers, merge/split, OCR retry).
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../common/keyboard_dismiss_scope.dart';
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

class _TopicDraftDialogResult {
  const _TopicDraftDialogResult(this.title, this.capacity);
  final String title;
  final int capacity;
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

  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _selecting = false;
  final Set<int> _selectedIndices = {};

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
    _searchCtrl.addListener(() => setState(() => _query = _searchCtrl.text));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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

  List<int> get _filteredIndices {
    final q = _query.trim().toLowerCase();
    final topics = _controller.topics;
    if (q.isEmpty) return List.generate(topics.length, (i) => i);
    return [
      for (var i = 0; i < topics.length; i++)
        if (topics[i].title.toLowerCase().contains(q)) i,
    ];
  }

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

    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PickerSheet<String>(
        title: 'Лист Excel',
        options: sheets,
        initial: _excelSheetName ?? sheets.first,
        labelBuilder: (s) => s,
      ),
    );

    if (selected == null || selected == _excelSheetName) return;
    await _reparseExcel(sheetName: selected);
  }

  Future<void> _showExcelColumnPicker() async {
    final headers = _parseResult?.excelHeaders;
    if (headers == null || headers.isEmpty) return;

    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _PickerSheet<int>(
        title: 'Столбец с темами',
        options: List.generate(headers.length, (i) => i),
        initial: (_excelColumnIndex ?? 0).clamp(0, headers.length - 1),
        labelBuilder: (i) =>
            headers[i].isEmpty ? 'Столбец ${i + 1}' : headers[i],
      ),
    );

    if (selected == null || selected == _excelColumnIndex) return;
    await _reparseExcel(columnIndex: selected);
  }

  Future<_TopicDraftDialogResult?> _showTopicEditorSheet(
      {TopicDraft? existing}) {
    return showModalBottomSheet<_TopicDraftDialogResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _TopicEditorSheet(
        initialTitle: existing?.title ?? '',
        initialCapacity: existing?.capacity ?? 1,
        isNew: existing == null,
      ),
    );
  }

  Future<void> _addOption() async {
    if (_controller.length >= topicListMaxTopics) return;
    final draft = await _showTopicEditorSheet();
    if (draft == null) return;
    setState(
        () => _controller.add(title: draft.title, capacity: draft.capacity));
  }

  void _dedupe() {
    setState(() => _controller.dedupe());
  }

  void _removeEmpty() {
    setState(() => _controller.removeEmpty());
  }

  Future<void> _editOption(int index) async {
    final topic = _controller.topics[index];
    final draft = await _showTopicEditorSheet(existing: topic);
    if (draft == null) return;
    setState(() {
      _controller.editAt(index, title: draft.title, capacity: draft.capacity);
    });
  }

  void _deleteOption(int index) {
    final removed = _controller.topics[index];
    setState(() => _controller.removeAt(index));

    // Drafts live only in local state (nothing published yet), so undo is a
    // plain re-insert — no server round trip needed.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Тема «${removed.title}» удалена'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Отменить',
          onPressed: () {
            if (!mounted) return;
            setState(() => _controller.insertAt(index, removed));
          },
        ),
      ),
    );
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selectedIndices.clear();
    });
  }

  void _toggleSelect(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  Future<void> _bulkDelete() async {
    if (_selectedIndices.isEmpty) return;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ConfirmSheet(
        title: 'Удалить темы?',
        message: 'Будет удалено тем: ${_selectedIndices.length}.',
        confirmLabel: 'Удалить',
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _controller.removeIndices(_selectedIndices);
      _selectedIndices.clear();
      _selecting = false;
    });
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
    final theme = Theme.of(context);
    final topics = _controller.topics;
    final warnings = _parseResult?.warnings ?? const <String>[];
    final duplicates = _controller.duplicateKeys;
    final filteredIndices = _filteredIndices;
    final canReorder = _query.trim().isEmpty && !_selecting;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: KeyboardDismissScope(
                child: CustomScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                IconButton(
                                  tooltip: 'Назад',
                                  onPressed: _publishing
                                      ? null
                                      : () => Navigator.of(context).pop(),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                                const Spacer(),
                                if (_hasExcelSheets)
                                  IconButton(
                                    tooltip: 'Лист Excel',
                                    onPressed: _reparsing
                                        ? null
                                        : _showExcelSheetPicker,
                                    icon: const Icon(Icons.tab_outlined),
                                  ),
                                if (_hasExcelHeaders)
                                  IconButton(
                                    tooltip: 'Столбец Excel',
                                    onPressed: _reparsing
                                        ? null
                                        : _showExcelColumnPicker,
                                    icon:
                                        const Icon(Icons.table_chart_outlined),
                                  ),
                                if (!_selecting && topics.isNotEmpty)
                                  TextButton(
                                    onPressed: _toggleSelecting,
                                    child: const Text('Выбрать'),
                                  )
                                else if (_selecting)
                                  TextButton(
                                    onPressed: _toggleSelecting,
                                    child: const Text('Готово'),
                                  ),
                              ],
                            ),
                            const _ReviewHeroHeader(),
                            const SizedBox(height: 16),
                            _SectionLabel(
                              icon: Icons.list_alt_rounded,
                              label: 'Темы',
                              trailing: '${topics.length}',
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _searchCtrl,
                              textInputAction: TextInputAction.search,
                              decoration: InputDecoration(
                                labelText: 'Поиск темы',
                                prefixIcon: const Icon(Icons.search_rounded),
                                suffixIcon: _query.isEmpty
                                    ? null
                                    : IconButton(
                                        icon: const Icon(Icons.close_rounded,
                                            size: 18),
                                        onPressed: _searchCtrl.clear,
                                      ),
                                filled: true,
                                fillColor: const Color(0xFFF6F7FB),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide.none,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: const BorderSide(
                                      color: Color(0xFFE1E5EF)),
                                ),
                              ),
                            ),
                            if (_reparsing) ...[
                              const SizedBox(height: 10),
                              const LinearProgressIndicator(minHeight: 2),
                              if (_reparseProgress != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    _reparseProgress!,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                            ],
                            if (warnings.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _WarningBanner(text: warnings.join('\n')),
                            ],
                            if (duplicates.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              _WarningBanner(
                                text:
                                    'Возможные дубли: ${duplicates.length}. Нажмите '
                                    '«Убрать дубли», чтобы очистить список.',
                                actionLabel: 'Убрать дубли',
                                onAction: _dedupe,
                              ),
                            ],
                            if (_controller.emptyCount > 0) ...[
                              const SizedBox(height: 10),
                              _WarningBanner(
                                text:
                                    'Пустых строк: ${_controller.emptyCount}.',
                                actionLabel: 'Убрать пустые',
                                onAction: _removeEmpty,
                              ),
                            ],
                            if (_controller.length >= topicListMaxTopics) ...[
                              const SizedBox(height: 10),
                              _WarningBanner(
                                text: 'Достигнут лимит $topicListMaxTopics тем',
                              ),
                            ],
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                    if (topics.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                          child: Text(
                            'Темы пока не добавлены',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: Colors.black45),
                          ),
                        ),
                      )
                    else if (filteredIndices.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                          child: Text(
                            'Темы не найдены',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: Colors.black45),
                          ),
                        ),
                      )
                    else if (canReorder)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        sliver: SliverReorderableList(
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
                            return _TopicRow(
                              key: ValueKey('topic_$index${opt.title}'),
                              topic: opt,
                              index: index,
                              isDuplicate: duplicates
                                  .contains(opt.title.trim().toLowerCase()),
                              selecting: _selecting,
                              selected: _selectedIndices.contains(index),
                              dragHandle: ReorderableDragStartListener(
                                index: index,
                                child: const Icon(Icons.drag_handle_rounded),
                              ),
                              onTap: _selecting
                                  ? () => _toggleSelect(index)
                                  : null,
                              onEdit: () => _editOption(index),
                              onDelete: () => _deleteOption(index),
                              onMore: () => _showRowMenu(index),
                            );
                          },
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final index = filteredIndices[i];
                              final opt = topics[index];
                              return _TopicRow(
                                key: ValueKey('topic_$index${opt.title}'),
                                topic: opt,
                                index: index,
                                isDuplicate: duplicates
                                    .contains(opt.title.trim().toLowerCase()),
                                selecting: _selecting,
                                selected: _selectedIndices.contains(index),
                                dragHandle: null,
                                onTap: _selecting
                                    ? () => _toggleSelect(index)
                                    : null,
                                onEdit: () => _editOption(index),
                                onDelete: () => _deleteOption(index),
                                onMore: () => _showRowMenu(index),
                              );
                            },
                            childCount: filteredIndices.length,
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  ],
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: _bottomBar(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRowMenu(int index) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _RowMenuSheet(
        canMerge: index < _controller.length - 1,
        canSplit: true,
        canOcr: _canReparseImage,
        canExcelSheet: _hasExcelSheets,
        canExcelColumn: _hasExcelHeaders,
      ),
    );
    switch (action) {
      case 'merge':
        _mergeWithNext(index);
        break;
      case 'split':
        _splitLine(index);
        break;
      case 'ocr':
        await _reparseWithOcr();
        break;
      case 'excel_sheet':
        await _showExcelSheetPicker();
        break;
      case 'excel_column':
        await _showExcelColumnPicker();
        break;
    }
  }

  Widget _bottomBar() {
    final cs = Theme.of(context).colorScheme;
    if (_selecting) {
      return Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
              top: BorderSide(color: Colors.black.withValues(alpha: 0.06))),
        ),
        child: Row(
          children: [
            TextButton(
                onPressed: _toggleSelecting, child: const Text('Отмена')),
            const Spacer(),
            FilledButton.icon(
              onPressed: _selectedIndices.isEmpty ? null : _bulkDelete,
              icon: const Icon(Icons.delete_outline),
              label: Text('Удалить (${_selectedIndices.length})'),
              style: FilledButton.styleFrom(backgroundColor: cs.error),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
            top: BorderSide(color: Colors.black.withValues(alpha: 0.06))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed:
                _controller.length >= topicListMaxTopics ? null : _addOption,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Добавить тему'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _publishing ? null : _publish,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
            child: _publishing
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Опубликовать в чат'),
          ),
        ],
      ),
    );
  }
}

class _ReviewHeroHeader extends StatelessWidget {
  const _ReviewHeroHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
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
              child:
                  Icon(Icons.fact_check_outlined, color: cs.primary, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Проверка списка тем',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Colors.black,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Поправьте темы перед публикацией в чат',
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
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.icon, required this.label, this.trailing});
  final IconData icon;
  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w800, color: Colors.black87),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: Colors.black45, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.text, this.actionLabel, this.onAction});
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 18, color: Colors.orange.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.orange.shade900,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(message, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Отмена'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(backgroundColor: cs.error),
                      child: Text(confirmLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerSheet<T> extends StatefulWidget {
  const _PickerSheet({
    required this.title,
    required this.options,
    required this.initial,
    required this.labelBuilder,
  });

  final String title;
  final List<T> options;
  final T initial;
  final String Function(T) labelBuilder;

  @override
  State<_PickerSheet<T>> createState() => _PickerSheetState<T>();
}

class _PickerSheetState<T> extends State<_PickerSheet<T>> {
  late T _value = widget.initial;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final option in widget.options)
                      RadioListTile<T>(
                        value: option,
                        groupValue: _value,
                        title: Text(widget.labelBuilder(option)),
                        onChanged: (v) {
                          if (v != null) setState(() => _value = v);
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_value),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                child: const Text('Применить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RowMenuSheet extends StatelessWidget {
  const _RowMenuSheet({
    required this.canMerge,
    required this.canSplit,
    required this.canOcr,
    required this.canExcelSheet,
    required this.canExcelColumn,
  });

  final bool canMerge;
  final bool canSplit;
  final bool canOcr;
  final bool canExcelSheet;
  final bool canExcelColumn;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget tile(IconData icon, String label, String value) => ListTile(
          leading: Icon(icon, color: cs.primary),
          title: Text(label),
          onTap: () => Navigator.of(context).pop(value),
        );
    return Material(
      color: cs.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 42,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            if (canMerge)
              tile(Icons.merge_rounded, 'Объединить со следующей', 'merge'),
            if (canSplit)
              tile(Icons.call_split_rounded, 'Разделить строку', 'split'),
            if (canOcr)
              tile(Icons.document_scanner_outlined, 'Повторить OCR', 'ocr'),
            if (canExcelSheet)
              tile(Icons.tab_outlined, 'Выбрать лист Excel', 'excel_sheet'),
            if (canExcelColumn)
              tile(Icons.table_chart_outlined, 'Перевыбрать столбец Excel',
                  'excel_column'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _TopicEditorSheet extends StatefulWidget {
  const _TopicEditorSheet({
    required this.initialTitle,
    required this.initialCapacity,
    required this.isNew,
  });

  final String initialTitle;
  final int initialCapacity;
  final bool isNew;

  @override
  State<_TopicEditorSheet> createState() => _TopicEditorSheetState();
}

class _TopicEditorSheetState extends State<_TopicEditorSheet> {
  late final _titleCtrl = TextEditingController(text: widget.initialTitle);
  late final _capCtrl =
      TextEditingController(text: widget.initialCapacity.toString());

  @override
  void dispose() {
    _titleCtrl.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название темы')),
      );
      return;
    }
    final capacity =
        (int.tryParse(_capCtrl.text.trim()) ?? widget.initialCapacity)
            .clamp(1, 999);
    Navigator.of(context).pop(_TopicDraftDialogResult(title, capacity));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Material(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: KeyboardDismissScope(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Text(
                    widget.isNew ? 'Новая тема' : 'Изменить тему',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _titleCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Название'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _capCtrl,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: 'Мест'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _submit,
                    style:
                        FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopicRow extends StatelessWidget {
  const _TopicRow({
    super.key,
    required this.topic,
    required this.index,
    required this.isDuplicate,
    required this.selecting,
    required this.selected,
    required this.dragHandle,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onMore,
  });

  final TopicDraft topic;
  final int index;
  final bool isDuplicate;
  final bool selecting;
  final bool selected;
  final Widget? dragHandle;
  final VoidCallback? onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isEmptyTitle = topic.title.trim().isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? cs.primary.withValues(alpha: 0.10)
            : const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDuplicate || isEmptyTitle
                    ? Colors.orange.withValues(alpha: 0.55)
                    : const Color(0xFFE1E5EF),
              ),
            ),
            child: Row(
              children: [
                if (selecting)
                  Checkbox(value: selected, onChanged: (_) => onTap?.call())
                else
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${index + 1}',
                      style: TextStyle(
                        color: cs.primary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isEmptyTitle ? 'Пустая строка' : topic.title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: isEmptyTitle ? Colors.black38 : null,
                          fontStyle: isEmptyTitle
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Мест: ${topic.capacity}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      if (isDuplicate) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Похоже на другую тему в списке',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.orange.shade800,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!selecting) ...[
                  IconButton(
                    tooltip: 'Изменить',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: onDelete,
                    icon: Icon(Icons.delete_outline, size: 20, color: cs.error),
                  ),
                  IconButton(
                    tooltip: 'Ещё',
                    onPressed: onMore,
                    icon: const Icon(Icons.more_vert_rounded, size: 20),
                  ),
                  if (dragHandle != null) dragHandle!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
