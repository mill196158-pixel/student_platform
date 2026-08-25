import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/auth/admin_backend_config.dart';
import 'academic_document_draft.dart';
import 'academic_document_intake_service.dart';
import 'curriculum_plan_import_repository.dart';

class CurriculumDocumentReviewPanel extends StatefulWidget {
  const CurriculumDocumentReviewPanel({
    super.key,
    this.intakeService,
    this.importRepository,
    this.initialDraft,
    this.onRowsChanged,
  });

  final AcademicDocumentIntakeService? intakeService;
  final CurriculumPlanImportRepository? importRepository;
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
  late final CurriculumPlanImportRepository _repository =
      widget.importRepository ??
      (AdminBackendConfig.isDemoMode
          ? LocalCurriculumPlanImportRepository()
          : SupabaseCurriculumPlanImportRepository());
  AcademicDocumentDraft? _draft;
  List<CurriculumDraftRow> _rows = const [];
  bool _loading = false;
  bool _serverBusy = false;
  String? _error;
  CurriculumPlanTarget? _target;
  CurriculumPlanDryRunResult? _dryRun;
  CurriculumPlanApplyResult? _applyResult;
  List<CurriculumSubjectReference> _subjects = const [];
  int _draftRevision = 0;
  int _serverRequest = 0;

  final _directionCode = TextEditingController();
  final _directionName = TextEditingController();
  final _profileName = TextEditingController();
  final _qualification = TextEditingController();
  final _admissionYear = TextEditingController();
  final _nominalSemesters = TextEditingController();
  final _planCode = TextEditingController();
  final _versionLabel = TextEditingController(text: 'draft-1');
  AcademicStudyForm? _studyForm;

  @override
  void initState() {
    super.initState();
    for (final controller in _metadataControllers) {
      controller.addListener(_invalidateServerPreview);
    }
    _loadSubjects();
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
    _versionLabel.dispose();
    super.dispose();
  }

  List<TextEditingController> get _metadataControllers => [
    _directionCode,
    _directionName,
    _profileName,
    _qualification,
    _admissionYear,
    _nominalSemesters,
    _planCode,
    _versionLabel,
  ];

  void _invalidateServerPreview() {
    _draftRevision++;
    if (!mounted) return;
    if (_dryRun == null && _target == null && _applyResult == null) return;
    setState(() {
      _target = null;
      _dryRun = null;
      _applyResult = null;
    });
  }

  Future<void> _loadSubjects() async {
    try {
      final subjects = await _repository.listSubjects();
      if (!mounted || (subjects.isEmpty && _subjects.isEmpty)) return;
      setState(() => _subjects = subjects);
    } catch (_) {
      // Exact name matching remains available. Ambiguous matches fail closed
      // in the server validator instead of guessing a subject.
    }
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
      _target = null;
      _dryRun = null;
      _applyResult = null;
      _error = null;
    }

    if (notify) {
      setState(update);
    } else {
      update();
    }
  }

  void _reset() {
    _draftRevision++;
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
      _target = null;
      _dryRun = null;
      _applyResult = null;
      _error = null;
    });
  }

  void _updateRow(int index, CurriculumDraftRow value) {
    _draftRevision++;
    final rows = [..._rows];
    rows[index] = value;
    setState(() {
      _rows = rows;
      _target = null;
      _dryRun = null;
      _applyResult = null;
    });
    widget.onRowsChanged?.call(List.unmodifiable(rows));
  }

  CurriculumDraftMetadata _reviewedMetadata() {
    return CurriculumDraftMetadata(
      directionCode: _directionCode.text.trim(),
      directionName: _directionName.text.trim(),
      profileName: _profileName.text.trim(),
      qualification: _qualification.text.trim(),
      studyForm: _studyForm,
      admissionYear: int.tryParse(_admissionYear.text.trim()),
      nominalSemesters: int.tryParse(_nominalSemesters.text.trim()),
      planCode: _planCode.text.trim(),
    );
  }

  Future<void> _runServerDryRun() async {
    final draft = _draft;
    if (draft == null) return;
    final revision = _draftRevision;
    final request = ++_serverRequest;
    setState(() {
      _serverBusy = true;
      _error = null;
      _applyResult = null;
    });
    try {
      final target = await _repository.ensureDraftTarget(
        metadata: _reviewedMetadata(),
        versionLabel: _versionLabel.text,
        source: draft,
      );
      if (!mounted || revision != _draftRevision || request != _serverRequest) {
        return;
      }
      final result = await _repository.dryRun(
        target: target,
        source: draft,
        rows: _rows,
      );
      if (!mounted || revision != _draftRevision || request != _serverRequest) {
        return;
      }
      setState(() {
        _target = target;
        _dryRun = result;
      });
    } catch (error) {
      if (mounted && request == _serverRequest) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && request == _serverRequest) {
        setState(() => _serverBusy = false);
      }
    }
  }

  Future<void> _applyServerPreview() async {
    final target = _target;
    final preview = _dryRun;
    if (target == null ||
        preview == null ||
        !preview.applyEnabled ||
        preview.previewId == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) =>
          _PlanApplyConfirmationDialog(planCode: target.planCode),
    );
    if (confirmed != true) return;

    final revision = _draftRevision;
    final request = ++_serverRequest;
    setState(() {
      _serverBusy = true;
      _error = null;
    });
    try {
      final result = await _repository.apply(
        previewId: preview.previewId!,
        confirmPlanCode: target.planCode,
      );
      if (!mounted || revision != _draftRevision || request != _serverRequest) {
        return;
      }
      setState(() => _applyResult = result);
    } catch (error) {
      if (mounted && request == _serverRequest) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && request == _serverRequest) {
        setState(() => _serverBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;
    final reviewReady =
        draft != null &&
        !draft.isManualRequired &&
        draft.blockingIssues.isEmpty &&
        _rows.isNotEmpty &&
        !_rows.any((row) => row.requiresReview);
    final previewReady =
        _dryRun?.ok == true &&
        _dryRun?.applyEnabled == true &&
        _dryRun?.previewId != null;
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
              onPressed: _loading || _serverBusy ? null : _pickDocument,
              icon: const Icon(Icons.upload_file_outlined),
              label: Text(draft == null ? 'Выбрать файл' : 'Заменить'),
            ),
            if (draft != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _loading || _serverBusy ? null : _reset,
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
            Expanded(
              child: IgnorePointer(
                ignoring: _serverBusy,
                child: _buildReview(draft),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  draft.isManualRequired
                      ? 'Продолжение невозможно: нужен ручной ввод или OCR.'
                      : _applyResult != null
                      ? 'Сохранение завершено. Следующий этап — привязка плана '
                            'к группе и подготовка семестра.'
                      : previewReady
                      ? 'Dry-run прошёл. Сохранение не создаёт offering, '
                            'команды или чаты.'
                      : 'Подтвердите все строки, затем запустите серверную '
                            'проверку.',
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _serverBusy || _applyResult != null
                    ? null
                    : previewReady
                    ? _applyServerPreview
                    : reviewReady
                    ? _runServerDryRun
                    : null,
                icon: _serverBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        previewReady
                            ? Icons.save_outlined
                            : Icons.fact_check_outlined,
                      ),
                label: Text(
                  previewReady ? 'Сохранить план' : 'Проверить на сервере',
                ),
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
        if (_dryRun != null) ...[
          _PlanDryRunSummary(result: _dryRun!),
          const SizedBox(height: 8),
        ],
        if (_applyResult != null) ...[
          _MessageCard(
            icon: Icons.check_circle_outline,
            color: Colors.green,
            messages: [
              _applyResult!.replayed
                  ? 'План уже был сохранён ранее; повтор не создал дублей.'
                  : 'Учебный план сохранён. Offering и команды создаются '
                        'отдельным этапом.',
            ],
          ),
          const SizedBox(height: 8),
        ],
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
                key: ValueKey(_studyForm),
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
                onChanged: (value) {
                  setState(() {
                    _draftRevision++;
                    _studyForm = value;
                    _target = null;
                    _dryRun = null;
                    _applyResult = null;
                  });
                },
              ),
            ),
            _field(_admissionYear, 'Год поступления', width: 160),
            _field(_nominalSemesters, 'Семестров', width: 130),
            _field(_planCode, 'Код файла плана', width: 300),
            _field(_versionLabel, 'Версия плана', width: 180),
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
            subjects: _subjects,
            maxSemesters: int.tryParse(_nominalSemesters.text) ?? 12,
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

class _PlanApplyConfirmationDialog extends StatefulWidget {
  const _PlanApplyConfirmationDialog({required this.planCode});

  final String planCode;

  @override
  State<_PlanApplyConfirmationDialog> createState() =>
      _PlanApplyConfirmationDialogState();
}

class _PlanApplyConfirmationDialogState
    extends State<_PlanApplyConfirmationDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Сохранить учебный план'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Предметы будут записаны в выбранную версию плана. '
            'Offering, команды, чаты и текущий семестр не изменятся.',
          ),
          const SizedBox(height: 12),
          Text('Для подтверждения введите код: ${widget.planCode}'),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'Код плана',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _controller.text.trim() == widget.planCode,
          ),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _PlanDryRunSummary extends StatelessWidget {
  const _PlanDryRunSummary({required this.result});

  final CurriculumPlanDryRunResult result;

  @override
  Widget build(BuildContext context) {
    final summary = result.summary;
    final errors =
        int.tryParse('${summary['error'] ?? summary['blocked'] ?? 0}') ?? 0;
    final issueLabels = <String>[
      for (final item in result.items)
        for (final error in (item['errors'] as List? ?? const []))
          'Строка ${item['row_number'] ?? '?'}: $error',
    ];
    return Card(
      color: result.ok
          ? Colors.green.withValues(alpha: 0.08)
          : Colors.orange.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(
              result.ok ? Icons.verified_outlined : Icons.warning_amber_rounded,
              color: result.ok ? Colors.green : Colors.orange,
            ),
            Text(
              result.ok
                  ? 'Проверка пройдена'
                  : 'Проверка не пройдена: ошибок $errors',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Chip(
              label: Text(
                'новых ${summary['new'] ?? summary['inserted'] ?? 0}',
              ),
            ),
            Chip(
              label: Text(
                'изменений ${summary['update'] ?? summary['updated'] ?? 0}',
              ),
            ),
            Chip(label: Text('без изменений ${summary['unchanged'] ?? 0}')),
            if (!result.applyEnabled && result.applyBlocker != null)
              Text(
                'Блокер: ${result.applyBlocker}',
                style: const TextStyle(color: Colors.red),
              ),
            for (final issue in issueLabels.take(5))
              SizedBox(
                width: double.infinity,
                child: Text(issue, style: const TextStyle(color: Colors.red)),
              ),
          ],
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
            const Text(
              'Источник просмотрен администратором; байты сервером не проверены',
            ),
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
    required this.subjects,
    required this.maxSemesters,
    required this.onChanged,
  });

  final CurriculumDraftRow row;
  final List<CurriculumSubjectReference> subjects;
  final int maxSemesters;
  final ValueChanged<CurriculumDraftRow> onChanged;

  @override
  State<_CurriculumRowEditor> createState() => _CurriculumRowEditorState();
}

class _CurriculumRowEditorState extends State<_CurriculumRowEditor> {
  late final _index = TextEditingController(text: widget.row.subjectIndex);
  late final _name = TextEditingController(text: widget.row.subjectName);
  late final _hours = TextEditingController(
    text: widget.row.hoursTotal?.toString() ?? '',
  );
  late final _credits = TextEditingController(
    text: widget.row.credits?.toString() ?? '',
  );
  int? _newSemester;

  @override
  void dispose() {
    _index.dispose();
    _name.dispose();
    _hours.dispose();
    _credits.dispose();
    super.dispose();
  }

  void _emit({
    bool? confirmed,
    CurriculumRowDisposition? disposition,
    String? subjectId,
    bool clearSubjectId = false,
    bool materialEdit = false,
    bool nestedEdit = false,
    List<CurriculumDraftOccurrence>? editedOccurrences,
    List<CurriculumDraftAssessment>? editedUnresolvedAssessments,
  }) {
    final nextDisposition = disposition ?? widget.row.disposition;
    final nextConfirmed = materialEdit
        ? false
        : (confirmed ?? widget.row.reviewerConfirmed);
    final isOccurrence = nextDisposition == CurriculumRowDisposition.occurrence;
    final hours = int.tryParse(_hours.text.trim());
    final credits = num.tryParse(_credits.text.trim().replaceAll(',', '.'));
    final name = _name.text.trim();
    final sourceOccurrences = editedOccurrences ?? widget.row.occurrences;
    final unresolved =
        editedUnresolvedAssessments ?? widget.row.unresolvedAssessments;
    final occurrences = isOccurrence
        ? sourceOccurrences
              .map(
                (occurrence) => occurrence.copyWith(
                  reviewerConfirmed: nextConfirmed,
                  assessments: occurrence.assessments
                      .map(
                        (assessment) => assessment.copyWith(
                          reviewerConfirmed: nextConfirmed,
                        ),
                      )
                      .toList(growable: false),
                ),
              )
              .toList(growable: false)
        : widget.row.occurrences;
    final issues = <String>[
      ...widget.row.blockingIssues.where(
        (issue) =>
            !_editorManagedIssues.contains(issue) &&
            !(nestedEdit && _isNestedEditorManagedIssue(issue)),
      ),
      if (nextDisposition == CurriculumRowDisposition.occurrence &&
          occurrences.isEmpty)
        'semester_required',
      if (name.isEmpty) 'subject_name_required',
      if (isOccurrence && unresolved.isNotEmpty)
        'assessment_semester_unresolved',
      if (!nextConfirmed) 'review_confirmation_required',
      if (nextDisposition == CurriculumRowDisposition.undecided)
        'aggregate_parent_decision_required',
      if (nestedEdit)
        for (final occurrence in occurrences)
          for (final type in CurriculumAssessmentType.values)
            if (occurrence.assessments
                    .where((assessment) => assessment.type == type)
                    .length >
                1)
              'duplicate_assessment:${type.wire}:'
                  '${occurrence.semesterNumber}',
    ];
    widget.onChanged(
      widget.row.copyWith(
        subjectId: subjectId,
        clearSubjectId: clearSubjectId,
        subjectIndex: _index.text.trim(),
        subjectName: name,
        occurrences: occurrences,
        unresolvedAssessments: unresolved,
        hoursTotal: hours,
        clearHoursTotal: hours == null,
        credits: credits,
        clearCredits: credits == null,
        blockingIssues: issues,
        reviewerConfirmed: nextConfirmed,
        disposition: nextDisposition,
      ),
    );
  }

  void _replaceOccurrence(int index, CurriculumDraftOccurrence occurrence) {
    final occurrences = [...widget.row.occurrences];
    occurrences[index] = occurrence;
    _emit(materialEdit: true, nestedEdit: true, editedOccurrences: occurrences);
  }

  void _removeOccurrence(int index) {
    final occurrences = [...widget.row.occurrences]..removeAt(index);
    _emit(materialEdit: true, nestedEdit: true, editedOccurrences: occurrences);
  }

  void _addOccurrence(int semester) {
    if (widget.row.occurrences.any(
      (occurrence) => occurrence.semesterNumber == semester,
    )) {
      return;
    }
    final occurrences = [
      ...widget.row.occurrences,
      CurriculumDraftOccurrence(
        semesterNumber: semester,
        sourcePage: widget.row.sourcePage,
        sourceRegion: widget.row.sourceRegion,
      ),
    ]..sort((a, b) => a.semesterNumber.compareTo(b.semesterNumber));
    _emit(materialEdit: true, nestedEdit: true, editedOccurrences: occurrences);
  }

  void _resolveAssessment(int unresolvedIndex, int semester) {
    final unresolved = [...widget.row.unresolvedAssessments];
    final assessment = unresolved
        .removeAt(unresolvedIndex)
        .copyWith(semesterNumber: semester, reviewerConfirmed: false);
    final occurrences = [...widget.row.occurrences];
    final occurrenceIndex = occurrences.indexWhere(
      (occurrence) => occurrence.semesterNumber == semester,
    );
    if (occurrenceIndex < 0) {
      occurrences.add(
        CurriculumDraftOccurrence(
          semesterNumber: semester,
          sourcePage: assessment.sourcePage,
          sourceRegion: assessment.sourceRegion,
          assessments: [assessment],
        ),
      );
    } else {
      final occurrence = occurrences[occurrenceIndex];
      final assessments = [...occurrence.assessments];
      if (!assessments.any((item) => item.type == assessment.type)) {
        assessments.add(assessment);
      }
      occurrences[occurrenceIndex] = occurrence.copyWith(
        assessments: assessments,
        reviewerConfirmed: false,
      );
    }
    occurrences.sort((a, b) => a.semesterNumber.compareTo(b.semesterNumber));
    _emit(
      materialEdit: true,
      nestedEdit: true,
      editedOccurrences: occurrences,
      editedUnresolvedAssessments: unresolved,
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
                if (widget.subjects.isNotEmpty)
                  SizedBox(
                    width: 320,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(widget.row.subjectId),
                      initialValue:
                          widget.subjects.any(
                            (item) => item.id == widget.row.subjectId,
                          )
                          ? widget.row.subjectId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Предмет из базы (если найден неоднозначно)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                          value: null,
                          child: Text('Автоматически по точному названию'),
                        ),
                        for (final subject in widget.subjects)
                          DropdownMenuItem(
                            value: subject.id,
                            child: Text(
                              subject.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => _emit(
                        subjectId: value,
                        clearSubjectId: value == null,
                        materialEdit: true,
                      ),
                    ),
                  ),
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
                  _hours,
                  'Всего часов',
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
              ],
            ),
            if (widget.row.disposition ==
                CurriculumRowDisposition.occurrence) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (
                      var occurrenceIndex = 0;
                      occurrenceIndex < widget.row.occurrences.length;
                      occurrenceIndex++
                    )
                      _OccurrenceEditor(
                        key: ValueKey(
                          '${widget.row.candidateKey}:'
                          '${widget.row.occurrences[occurrenceIndex].semesterNumber}',
                        ),
                        occurrence: widget.row.occurrences[occurrenceIndex],
                        maxSemesters: widget.maxSemesters,
                        onChanged: (value) =>
                            _replaceOccurrence(occurrenceIndex, value),
                        onRemove: () => _removeOccurrence(occurrenceIndex),
                      ),
                    for (
                      var unresolvedIndex = 0;
                      unresolvedIndex < widget.row.unresolvedAssessments.length;
                      unresolvedIndex++
                    )
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${widget.row.unresolvedAssessments[unresolvedIndex].type.label}: '
                                'семестр «${widget.row.unresolvedAssessments[unresolvedIndex].rawValue}» '
                                'не распознан',
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: DropdownButtonFormField<int>(
                                key: ValueKey(
                                  'resolve:${widget.row.candidateKey}:'
                                  '$unresolvedIndex',
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Указать семестр',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  for (
                                    var semester = 1;
                                    semester <= widget.maxSemesters;
                                    semester++
                                  )
                                    DropdownMenuItem(
                                      value: semester,
                                      child: Text('$semester'),
                                    ),
                                ],
                                onChanged: (semester) {
                                  if (semester != null) {
                                    _resolveAssessment(
                                      unresolvedIndex,
                                      semester,
                                    );
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 170,
                          child: DropdownButtonFormField<int>(
                            initialValue: _newSemester,
                            decoration: const InputDecoration(
                              labelText: 'Новый семестр',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: [
                              for (
                                var semester = 1;
                                semester <= widget.maxSemesters;
                                semester++
                              )
                                DropdownMenuItem(
                                  value: semester,
                                  child: Text('$semester'),
                                ),
                            ],
                            onChanged: (value) =>
                                setState(() => _newSemester = value),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _newSemester == null
                              ? null
                              : () => _addOccurrence(_newSemester!),
                          icon: const Icon(Icons.add),
                          label: const Text('Добавить семестр'),
                        ),
                        for (final issue in widget.row.blockingIssues)
                          if (_blockingIssueLabel(issue) case final label?)
                            Chip(
                              avatar: const Icon(Icons.error_outline, size: 18),
                              label: Text(label),
                            ),
                        if (widget.row.occurrences.isEmpty)
                          const Chip(
                            avatar: Icon(Icons.warning_amber_rounded, size: 18),
                            label: Text('Семестр не распознан'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
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

const _editorManagedIssues = {
  'semester_required',
  'subject_name_required',
  'review_confirmation_required',
  'aggregate_parent_decision_required',
};

bool _isNestedEditorManagedIssue(String issue) =>
    issue == 'assessment_semester_unresolved' ||
    issue.startsWith('assessment_semester_unresolved:') ||
    issue.startsWith('duplicate_assessment:');

String? _blockingIssueLabel(String issue) {
  if (issue.startsWith('assessment_semester_unresolved:')) return null;
  final parts = issue.split(':');
  if (parts.length == 3 && parts.first == 'duplicate_assessment') {
    final type = CurriculumAssessmentType.values
        .where((value) => value.wire == parts[1])
        .firstOrNull;
    return 'Повторная форма контроля: '
        '${type?.label ?? 'неизвестная форма'}, семестр ${parts[2]}';
  }
  return null;
}

class _OccurrenceEditor extends StatelessWidget {
  const _OccurrenceEditor({
    super.key,
    required this.occurrence,
    required this.maxSemesters,
    required this.onChanged,
    required this.onRemove,
  });

  final CurriculumDraftOccurrence occurrence;
  final int maxSemesters;
  final ValueChanged<CurriculumDraftOccurrence> onChanged;
  final VoidCallback onRemove;

  void _changeSemester(int semester) {
    onChanged(
      occurrence.copyWith(
        semesterNumber: semester,
        reviewerConfirmed: false,
        assessments: occurrence.assessments
            .map(
              (assessment) => assessment.copyWith(
                semesterNumber: semester,
                reviewerConfirmed: false,
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  void _changeWorkload(String key, String value) {
    final workload = {...occurrence.workload};
    final normalized = value.trim().replaceAll(',', '.');
    if (normalized.isEmpty) {
      workload.remove(key);
    } else {
      final parsed = num.tryParse(normalized);
      if (parsed == null || parsed < 0) return;
      workload[key] = parsed;
    }
    onChanged(
      occurrence.copyWith(workload: workload, reviewerConfirmed: false),
    );
  }

  void _toggleAssessment(CurriculumAssessmentType type, bool selected) {
    final assessments = [...occurrence.assessments];
    if (selected) {
      if (!assessments.any((assessment) => assessment.type == type)) {
        assessments.add(
          CurriculumDraftAssessment(
            type: type,
            semesterNumber: occurrence.semesterNumber,
            rawValue: type.wire,
            sourcePage: occurrence.sourcePage,
            sourceRegion: occurrence.sourceRegion,
          ),
        );
      }
    } else {
      assessments.removeWhere((assessment) => assessment.type == type);
    }
    onChanged(
      occurrence.copyWith(assessments: assessments, reviewerConfirmed: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    final workloadEntries = occurrence.workload.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Colors.blue.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('semester:${occurrence.semesterNumber}'),
                    initialValue: occurrence.semesterNumber,
                    decoration: const InputDecoration(
                      labelText: 'Семестр',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (
                        var semester = 1;
                        semester <= maxSemesters;
                        semester++
                      )
                        DropdownMenuItem(
                          value: semester,
                          child: Text('$semester'),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) _changeSemester(value);
                    },
                  ),
                ),
                for (final entry in workloadEntries)
                  SizedBox(
                    width: 170,
                    child: TextFormField(
                      key: ValueKey(
                        'workload:${occurrence.semesterNumber}:${entry.key}',
                      ),
                      initialValue: entry.value.toString(),
                      onChanged: (value) => _changeWorkload(entry.key, value),
                      decoration: InputDecoration(
                        labelText: entry.key,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Удалить семестр',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Формы контроля',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final type in CurriculumAssessmentType.values)
                  if (type != CurriculumAssessmentType.unknown)
                    FilterChip(
                      label: Text(type.label),
                      selected: occurrence.assessments.any(
                        (assessment) => assessment.type == type,
                      ),
                      onSelected: (selected) =>
                          _toggleAssessment(type, selected),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
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
