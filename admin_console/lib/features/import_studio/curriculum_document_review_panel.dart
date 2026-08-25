import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'academic_document_draft.dart';
import 'academic_document_intake_service.dart';

class CurriculumDocumentReviewPanel extends StatefulWidget {
  const CurriculumDocumentReviewPanel({
    super.key,
    this.intakeService,
    this.initialDraft,
    this.onRowsChanged,
  });

  final AcademicDocumentIntakeService? intakeService;
  final AcademicDocumentDraft? initialDraft;
  final ValueChanged<List<CurriculumDraftRow>>? onRowsChanged;

  @override
  State<CurriculumDocumentReviewPanel> createState() =>
      _CurriculumDocumentReviewPanelState();
}

class _CurriculumDocumentReviewPanelState
    extends State<CurriculumDocumentReviewPanel> {
  late final AcademicDocumentIntakeService _intake =
      widget.intakeService ?? AcademicDocumentIntakeService();
  AcademicDocumentDraft? _draft;
  List<CurriculumDraftRow> _rows = const [];
  bool _loading = false;
  String? _error;

  final _directionCode = TextEditingController();
  final _directionName = TextEditingController();
  final _profileName = TextEditingController();
  final _qualification = TextEditingController();
  final _admissionYear = TextEditingController();
  final _nominalSemesters = TextEditingController();
  final _planCode = TextEditingController();
  AcademicStudyForm? _studyForm;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialDraft;
    if (initial != null) _loadDraft(initial, notify: false);
  }

  @override
  void dispose() {
    _directionCode.dispose();
    _directionName.dispose();
    _profileName.dispose();
    _qualification.dispose();
    _admissionYear.dispose();
    _nominalSemesters.dispose();
    _planCode.dispose();
    super.dispose();
  }

  Future<void> _pickDocument() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'xlsx', 'png', 'jpg', 'jpeg', 'webp'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      setState(() => _error = 'Не удалось прочитать выбранный файл.');
      return;
    }

    _reset();
    setState(() => _loading = true);
    try {
      final draft = await _intake.read(bytes: bytes, fileName: file.name);
      if (!mounted) return;
      _loadDraft(draft);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Не удалось разобрать документ: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _loadDraft(AcademicDocumentDraft draft, {bool notify = true}) {
    final metadata = draft.metadata;
    _directionCode.text = metadata.directionCode ?? '';
    _directionName.text = metadata.directionName ?? '';
    _profileName.text = metadata.profileName ?? '';
    _qualification.text = metadata.qualification ?? '';
    _admissionYear.text = metadata.admissionYear?.toString() ?? '';
    _nominalSemesters.text = metadata.nominalSemesters?.toString() ?? '';
    _planCode.text = metadata.planCode ?? '';
    void update() {
      _draft = draft;
      _rows = draft.rows;
      _studyForm = metadata.studyForm;
      _error = null;
    }

    if (notify) {
      setState(update);
    } else {
      update();
    }
  }

  void _reset() {
    _directionCode.clear();
    _directionName.clear();
    _profileName.clear();
    _qualification.clear();
    _admissionYear.clear();
    _nominalSemesters.clear();
    _planCode.clear();
    if (!mounted) return;
    setState(() {
      _draft = null;
      _rows = const [];
      _studyForm = null;
      _error = null;
    });
  }

  void _updateRow(int index, CurriculumDraftRow value) {
    final rows = [..._rows];
    rows[index] = value;
    setState(() => _rows = rows);
    widget.onRowsChanged?.call(List.unmodifiable(rows));
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Учебный план из PDF / XLSX',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Распознавание создаёт черновик. В базу ничего не записывается.',
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: _loading ? null : _pickDocument,
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(draft == null ? 'Выбрать файл' : 'Заменить'),
            ),
            if (draft != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _loading ? null : _reset,
                child: const Text('Сбросить'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Поддерживаются XLSX, PDF и изображения до 20 МБ; PDF — до 500 '
          'страниц. Изображения и сканированные PDF требуют ручного заполнения.',
          style: TextStyle(color: Colors.black54),
        ),
        if (_loading) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          const Text('Извлекаем текст и координаты страниц…'),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          _MessageCard(
            icon: Icons.error_outline,
            color: Colors.red,
            messages: [_error!],
          ),
        ],
        if (draft != null) ...[
          const SizedBox(height: 12),
          _SourceSummary(draft: draft),
          const SizedBox(height: 12),
          if (draft.isManualRequired)
            _MessageCard(
              icon: Icons.document_scanner_outlined,
              color: Colors.orange,
              messages: draft.blockingIssues,
            )
          else
            Expanded(child: _buildReview(draft)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  draft.isManualRequired
                      ? 'Продолжение невозможно: нужен ручной ввод или OCR.'
                      : 'Продолжение отключено: сначала нужно подтвердить все '
                            'строки и подключить серверный dry-run.',
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
              const SizedBox(width: 12),
              const FilledButton(
                onPressed: null,
                child: Text('Продолжить к dry-run'),
              ),
            ],
          ),
        ] else if (!_loading) ...[
          const SizedBox(height: 48),
          const Center(
            child: Text(
              'Выберите официальный учебный план.\n'
              'Для ПГС 2025 можно загрузить имеющийся PDF.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildReview(AcademicDocumentDraft draft) {
    final unresolved = _rows.where((row) => row.requiresReview).length;
    return ListView(
      children: [
        _MessageCard(
          icon: Icons.shield_outlined,
          color: Colors.blue,
          messages: draft.warnings,
        ),
        if (draft.blockingIssues.isNotEmpty) ...[
          const SizedBox(height: 8),
          _MessageCard(
            icon: Icons.warning_amber_rounded,
            color: Colors.orange,
            messages: draft.blockingIssues,
          ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Программа и версия плана',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _field(_directionCode, 'Код направления', width: 170),
            _field(_directionName, 'Направление', width: 260),
            _field(_profileName, 'Профиль', width: 360),
            _field(_qualification, 'Квалификация', width: 180),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<AcademicStudyForm>(
                initialValue: _studyForm,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Форма обучения',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final value in AcademicStudyForm.values)
                    DropdownMenuItem(value: value, child: Text(value.label)),
                ],
                onChanged: (value) => setState(() => _studyForm = value),
              ),
            ),
            _field(_admissionYear, 'Год поступления', width: 160),
            _field(_nominalSemesters, 'Семестров', width: 130),
            _field(_planCode, 'Код файла плана', width: 300),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Кандидаты дисциплин',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            Chip(
              avatar: const Icon(Icons.fact_check_outlined, size: 18),
              label: Text(
                'Всего ${_rows.length} · требуют проверки $unresolved',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < _rows.length; index++)
          _CurriculumRowEditor(
            key: ValueKey(_rows[index].candidateKey),
            row: _rows[index],
            onChanged: (value) => _updateRow(index, value),
          ),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    required double width,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _SourceSummary extends StatelessWidget {
  const _SourceSummary({required this.draft});

  final AcademicDocumentDraft draft;

  @override
  Widget build(BuildContext context) {
    final diagnosis = switch (draft.diagnosis) {
      AcademicDocumentDiagnosis.textPdf => 'PDF с текстом',
      AcademicDocumentDiagnosis.xlsx => 'XLSX',
      AcademicDocumentDiagnosis.manualRequired => 'Нужен ручной ввод',
      AcademicDocumentDiagnosis.unsupported => 'Не поддерживается',
      AcademicDocumentDiagnosis.error => 'Ошибка',
    };
    final sizeKb = (draft.fileSize / 1024).toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 20,
          runSpacing: 6,
          children: [
            Text('Файл: ${draft.fileName}'),
            Text('Тип: $diagnosis'),
            Text('Размер: $sizeKb КБ'),
            if (draft.pageCount > 0) Text('Страниц: ${draft.pageCount}'),
            if (draft.sheetName != null) Text('Лист: ${draft.sheetName}'),
            Text('Контракт: ${draft.contractVersion}'),
            Text('Парсер: ${draft.parserVersion}'),
            Tooltip(
              message: draft.localSha256,
              child: Text('SHA-256: ${draft.localSha256.substring(0, 12)}…'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CurriculumRowEditor extends StatefulWidget {
  const _CurriculumRowEditor({
    super.key,
    required this.row,
    required this.onChanged,
  });

  final CurriculumDraftRow row;
  final ValueChanged<CurriculumDraftRow> onChanged;

  @override
  State<_CurriculumRowEditor> createState() => _CurriculumRowEditorState();
}

class _CurriculumRowEditorState extends State<_CurriculumRowEditor> {
  late final _index = TextEditingController(text: widget.row.subjectIndex);
  late final _name = TextEditingController(text: widget.row.subjectName);
  late final _semester = TextEditingController(
    text: widget.row.semesterNumber?.toString() ?? '',
  );
  late final _hours = TextEditingController(
    text: widget.row.hoursTotal?.toString() ?? '',
  );
  late final _credits = TextEditingController(
    text: widget.row.credits?.toString() ?? '',
  );
  late final _control = TextEditingController(
    text: widget.row.controlForm ?? '',
  );

  @override
  void dispose() {
    _index.dispose();
    _name.dispose();
    _semester.dispose();
    _hours.dispose();
    _credits.dispose();
    _control.dispose();
    super.dispose();
  }

  void _emit({
    bool? confirmed,
    CurriculumRowDisposition? disposition,
    bool materialEdit = false,
  }) {
    final nextDisposition = disposition ?? widget.row.disposition;
    final nextConfirmed = materialEdit
        ? false
        : (confirmed ?? widget.row.reviewerConfirmed);
    final isOccurrence = nextDisposition == CurriculumRowDisposition.occurrence;
    if (!isOccurrence && disposition != null) {
      _semester.clear();
      _hours.clear();
      _credits.clear();
      _control.clear();
    }
    final semester = isOccurrence ? int.tryParse(_semester.text.trim()) : null;
    final hours = isOccurrence ? int.tryParse(_hours.text.trim()) : null;
    final credits = isOccurrence
        ? num.tryParse(_credits.text.trim().replaceAll(',', '.'))
        : null;
    final control = isOccurrence ? _control.text.trim() : '';
    final name = _name.text.trim();
    final issues = <String>[
      if (nextDisposition == CurriculumRowDisposition.occurrence &&
          semester == null)
        'semester_required',
      if (name.isEmpty) 'subject_name_required',
      if (!nextConfirmed) 'review_confirmation_required',
      if (nextDisposition == CurriculumRowDisposition.undecided)
        'aggregate_parent_decision_required',
    ];
    widget.onChanged(
      widget.row.copyWith(
        subjectIndex: _index.text.trim(),
        subjectName: name,
        semesterNumber: semester,
        clearSemesterNumber: semester == null,
        hoursTotal: hours,
        clearHoursTotal: hours == null,
        credits: credits,
        clearCredits: credits == null,
        controlForm: control.isEmpty ? null : control,
        clearControlForm: control.isEmpty,
        blockingIssues: issues,
        reviewerConfirmed: nextConfirmed,
        disposition: nextDisposition,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _smallField(_index, 'Индекс', 130),
                _smallField(_name, 'Дисциплина', 380),
                if (widget.row.isAggregateCandidate)
                  SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<CurriculumRowDisposition>(
                      key: ValueKey(widget.row.disposition),
                      initialValue: widget.row.disposition,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Решение по строке',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final value in CurriculumRowDisposition.values)
                          DropdownMenuItem(
                            value: value,
                            child: Text(value.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          _emit(disposition: value, materialEdit: true);
                        }
                      },
                    ),
                  ),
                _smallField(
                  _semester,
                  'Семестр',
                  100,
                  enabled:
                      widget.row.disposition ==
                      CurriculumRowDisposition.occurrence,
                ),
                _smallField(
                  _hours,
                  'Часы',
                  90,
                  enabled:
                      widget.row.disposition ==
                      CurriculumRowDisposition.occurrence,
                ),
                _smallField(
                  _credits,
                  'З.е.',
                  90,
                  enabled:
                      widget.row.disposition ==
                      CurriculumRowDisposition.occurrence,
                ),
                _smallField(
                  _control,
                  'Контроль',
                  140,
                  enabled:
                      widget.row.disposition ==
                      CurriculumRowDisposition.occurrence,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Страница ${widget.row.sourcePage}'
                    '${widget.row.sourceRegion == null ? '' : ' · координаты сохранены'}'
                    '${widget.row.warnings.isEmpty ? '' : ' · ${widget.row.warnings.join(' ')}'}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
                Checkbox(
                  value: widget.row.reviewerConfirmed,
                  onChanged: (value) => _emit(confirmed: value == true),
                ),
                const Text('Проверено'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallField(
    TextEditingController controller,
    String label,
    double width, {
    bool enabled = true,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        enabled: enabled,
        onChanged: (_) => _emit(materialEdit: true),
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.icon,
    required this.color,
    required this.messages,
  });

  final IconData icon;
  final Color color;
  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(messages.map((message) => '• $message').join('\n')),
            ),
          ],
        ),
      ),
    );
  }
}
