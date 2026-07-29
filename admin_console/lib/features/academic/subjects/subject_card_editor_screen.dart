import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../teachers/teacher_item.dart';
import '../teachers/teachers_repository.dart';
import 'subject_item.dart';
import 'subjects_repository.dart';

/// Visual subject card editor (Stage 16.1 text/links/ordering foundation).
///
/// Images/files deferred to 16.2. Hours/credits shown only with offering.
/// Teachers editable only when an offering is **explicitly** selected.
class SubjectCardEditorScreen extends StatefulWidget {
  const SubjectCardEditorScreen({
    super.key,
    required this.repository,
    this.teachersRepository,
    this.session,
    this.item,
    this.selectedOfferingId,
    this.hoursTotal,
    this.credits,
  });

  final SubjectsRepository repository;
  final TeachersRepository? teachersRepository;
  final AdminSessionController? session;
  final SubjectItem? item;
  final String? selectedOfferingId;
  final num? hoursTotal;
  final num? credits;

  @override
  State<SubjectCardEditorScreen> createState() =>
      _SubjectCardEditorScreenState();
}

class _SubjectCardEditorScreenState extends State<SubjectCardEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _department;
  late final TextEditingController _control;
  late final TextEditingController _description;
  late final TextEditingController _short;
  late final TextEditingController _outcomes;
  late final TextEditingController _requirements;
  late final TextEditingController _expect;
  late final TextEditingController _howToPass;
  late final TextEditingController _materials;
  late final TextEditingController _pitfalls;
  late final TextEditingController _links;
  late final TextEditingController _relevance;

  late SubjectStatus _status;
  late List<String> _sectionOrder;
  bool _busy = false;
  String? _banner;
  List<SubjectOfferingAdminItem> _offerings = const [];
  String? _selectedOfferingId;
  final List<String> _selectedTeacherIds = [];
  final Map<String, String> _teacherLabels = {};
  final _teacherSearch = TextEditingController();
  List<TeacherItem> _teacherHits = const [];
  final _localDescription = TextEditingController();
  final _teacherNote = TextEditingController();
  final _assessmentNote = TextEditingController();
  final _workloadNote = TextEditingController();
  final _semesterTips = TextEditingController();
  late final TeachersRepository _teachersRepository =
      widget.teachersRepository ??
      (AdminBackendConfig.isDemoMode
          ? LocalTeachersRepository()
          : SupabaseTeachersRepository());

  bool get _canWrite =>
      widget.session == null ||
      widget.session!.isLocalPrototype ||
      widget.session!.capabilities.canWriteSubjects;

  SubjectOfferingAdminItem? get _selectedOffering {
    for (final o in _offerings) {
      if (o.id == _selectedOfferingId) return o;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item?.canonicalName ?? '');
    _department = TextEditingController(text: item?.department ?? '');
    _control = TextEditingController(text: item?.controlForm ?? '');
    _description = TextEditingController(text: item?.description ?? '');
    _short = TextEditingController(text: item?.shortDescription ?? '');
    _outcomes = TextEditingController(text: item?.learningOutcomes ?? '');
    _requirements = TextEditingController(text: item?.requirements ?? '');
    _expect = TextEditingController(text: item?.whatToExpect ?? '');
    _howToPass = TextEditingController(text: item?.howToPass ?? '');
    _materials = TextEditingController(text: item?.usefulMaterialsNote ?? '');
    _pitfalls = TextEditingController(text: item?.commonPitfalls ?? '');
    _links = TextEditingController(text: _linksToText(item?.usefulLinks));
    _relevance = TextEditingController(text: item?.relevanceDate ?? '');
    _status = item?.status ?? SubjectStatus.draft;
    _sectionOrder = normalizeSubjectCardSectionOrder(item?.sectionOrder);
    _selectedOfferingId = widget.selectedOfferingId;
    _loadOfferings();
  }

  Future<void> _loadOfferings() async {
    final id = widget.item?.id;
    if (id == null ||
        id.startsWith('local-') ||
        id.startsWith('new-') ||
        id == 'new') {
      return;
    }
    try {
      final offerings = await widget.repository.listOfferings(id);
      if (!mounted) return;
      setState(() {
        _offerings = offerings;
        // Explicit selection only — never auto-pick the first offering.
        if (_selectedOfferingId != null &&
            !offerings.any((o) => o.id == _selectedOfferingId)) {
          _selectedOfferingId = null;
        }
      });
      _bindOffering(_selectedOffering);
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = 'Offering list: $error');
    }
  }

  void _bindOffering(SubjectOfferingAdminItem? offering) {
    _selectedTeacherIds
      ..clear()
      ..addAll(offering?.teacherIds ?? const []);
    for (final id in _selectedTeacherIds) {
      _teacherLabels.putIfAbsent(id, () => id);
    }
    _localDescription.text = offering?.localDescription ?? '';
    _teacherNote.text = offering?.teacherSpecificNote ?? '';
    _assessmentNote.text = offering?.assessmentNote ?? '';
    _workloadNote.text = offering?.workloadNote ?? '';
    _semesterTips.text = offering?.semesterTips ?? '';
    if (offering != null && _selectedTeacherIds.isNotEmpty) {
      _hydrateTeacherLabels(_selectedTeacherIds);
    }
  }

  Future<void> _hydrateTeacherLabels(List<String> ids) async {
    try {
      final known = await _teachersRepository.list();
      if (!mounted) return;
      setState(() {
        for (final t in known) {
          if (ids.contains(t.id)) {
            _teacherLabels[t.id] = t.fullName;
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _searchTeachers(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() => _teacherHits = const []);
      return;
    }
    try {
      final rows = await _teachersRepository.list(query: q);
      if (!mounted) return;
      setState(() => _teacherHits = rows.take(20).toList());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _teacherHits = const [];
        _banner = 'Teacher search: $error';
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _department.dispose();
    _control.dispose();
    _description.dispose();
    _short.dispose();
    _outcomes.dispose();
    _requirements.dispose();
    _expect.dispose();
    _howToPass.dispose();
    _materials.dispose();
    _pitfalls.dispose();
    _links.dispose();
    _relevance.dispose();
    _teacherSearch.dispose();
    _localDescription.dispose();
    _teacherNote.dispose();
    _assessmentNote.dispose();
    _workloadNote.dispose();
    _semesterTips.dispose();
    super.dispose();
  }

  String _linksToText(List<dynamic>? links) {
    if (links == null) return '';
    return links
        .map((link) {
          if (link is Map) {
            final title = '${link['title'] ?? ''}'.trim();
            final url = '${link['url'] ?? ''}'.trim();
            if (title.isEmpty) return url;
            if (url.isEmpty) return title;
            return '$title|$url';
          }
          return '$link';
        })
        .where((line) => line.trim().isNotEmpty)
        .join('\n');
  }

  List<Map<String, String>> _parseLinks() {
    final out = <Map<String, String>>[];
    for (final line in _links.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('|');
      if (parts.length >= 2) {
        out.add({
          'title': parts.first.trim(),
          'url': parts.sublist(1).join('|').trim(),
        });
      } else {
        out.add({'title': trimmed, 'url': trimmed});
      }
    }
    return out;
  }

  SubjectCardPayload _previewPayload() {
    final links = <SubjectCardLink>[
      for (final row in _parseLinks())
        if (SubjectCardLink.tryParse(row) != null)
          SubjectCardLink.tryParse(row)!,
    ];
    final offering = _selectedOffering;
    final teachers = <SubjectCardTeacher>[
      if (offering != null)
        for (final id in _selectedTeacherIds)
          SubjectCardTeacher(
            id: id,
            displayName: _teacherLabels[id] ?? id,
          ),
    ];
    final description = _localDescription.text.trim().isNotEmpty
        ? _localDescription.text.trim()
        : _description.text.trim();
    final howToPass = _semesterTips.text.trim().isNotEmpty
        ? _semesterTips.text.trim()
        : _howToPass.text.trim();
    return SubjectCardPayload(
      subjectId: widget.item?.id ?? 'new',
      subjectOfferingId: offering?.id,
      canonicalName: _name.text.trim().isEmpty
          ? 'Без названия'
          : _name.text.trim(),
      sectionOrder: _sectionOrder,
      shortDescription: _short.text.trim().ifEmptyAsNull,
      description: description.ifEmptyAsNull,
      learningOutcomes: _outcomes.text.trim().ifEmptyAsNull,
      whatToExpect: _expect.text.trim().ifEmptyAsNull,
      howToPass: howToPass.ifEmptyAsNull,
      requirements: _requirements.text.trim().ifEmptyAsNull,
      usefulMaterialsNote: _materials.text.trim().ifEmptyAsNull,
      commonPitfalls: _pitfalls.text.trim().ifEmptyAsNull,
      controlForm: _control.text.trim().ifEmptyAsNull,
      department: _department.text.trim().ifEmptyAsNull,
      hoursTotal: offering?.hoursTotal ?? widget.hoursTotal,
      credits: offering?.credits ?? widget.credits,
      hoursCreditsAvailable: offering != null &&
          ((offering.hoursTotal ?? widget.hoursTotal) != null ||
              (offering.credits ?? widget.credits) != null),
      relevanceDate: DateTime.tryParse(_relevance.text.trim()),
      usefulLinks: links,
      teachers: teachers,
      teacherSpecificNote: _teacherNote.text.trim().ifEmptyAsNull,
      assessmentNote: _assessmentNote.text.trim().ifEmptyAsNull,
      workloadNote: _workloadNote.text.trim().ifEmptyAsNull,
    );
  }

  Future<void> _saveTeachers() async {
    final offering = _selectedOffering;
    if (offering == null || !_canWrite) return;
    setState(() => _busy = true);
    try {
      await widget.repository.setOfferingTeachers(
        offeringId: offering.id,
        expectedTeachersRowVersion: offering.teachersRowVersion,
        teacherIds: List<String>.from(_selectedTeacherIds),
      );
      await _loadOfferings();
      if (!mounted) return;
      setState(() => _banner = 'Преподаватели сохранены (offering_teachers).');
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showOfferingVersions() async {
    final offering = _selectedOffering;
    if (offering == null) return;
    try {
      final versions =
          await widget.repository.listOfferingProfileVersions(offering.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Override versions · ${offering.displayName ?? offering.id}'),
          content: SizedBox(
            width: 420,
            height: 280,
            child: versions.isEmpty
                ? const Text('Нет версий')
                : ListView.builder(
                    itemCount: versions.length,
                    itemBuilder: (context, index) {
                      final row = versions[index];
                      final n = row['version_number'];
                      return ListTile(
                        title: Text('v$n'),
                        subtitle: Text('${row['created_at'] ?? ''}'),
                        trailing: TextButton(
                          onPressed: () async {
                            Navigator.of(context).pop();
                            await widget.repository.restoreOfferingProfile(
                              offeringId: offering.id,
                              versionNumber: int.parse('$n'),
                              expectedRowVersion: offering.overrideRowVersion,
                            );
                            await _loadOfferings();
                            if (!mounted) return;
                            setState(
                              () => _banner = 'Override восстановлен из v$n',
                            );
                          },
                          child: const Text('Restore'),
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    }
  }

  Future<void> _saveOverride() async {
    final offering = _selectedOffering;
    if (offering == null || !_canWrite) return;
    setState(() => _busy = true);
    try {
      await widget.repository.saveOfferingOverride(
        offeringId: offering.id,
        expectedRowVersion: offering.overrideRowVersion,
        localDescription: _localDescription.text.trim().ifEmptyAsNull,
        teacherSpecificNote: _teacherNote.text.trim().ifEmptyAsNull,
        assessmentNote: _assessmentNote.text.trim().ifEmptyAsNull,
        workloadNote: _workloadNote.text.trim().ifEmptyAsNull,
        semesterTips: _semesterTips.text.trim().ifEmptyAsNull,
        moderationStatus: offering.overrideStatus ?? 'draft',
      );
      await _loadOfferings();
      if (!mounted) return;
      setState(() => _banner = 'Offering override сохранён.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_canWrite || _busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _banner = 'Название обязательно (не является ключом).');
      return;
    }
    setState(() {
      _busy = true;
      _banner = null;
    });
    try {
      final base = widget.item;
      final next = SubjectItem(
        id: base?.id ?? 'local-${DateTime.now().microsecondsSinceEpoch}',
        canonicalName: name,
        description: _description.text.trim(),
        department: _department.text.trim().isEmpty
            ? null
            : _department.text.trim(),
        controlForm: _control.text.trim().isEmpty ? null : _control.text.trim(),
        difficultyLabel: base?.difficultyLabel,
        requirements: _requirements.text.trim(),
        learningOutcomes: _outcomes.text.trim(),
        shortDescription: _short.text.trim(),
        whatToExpect: _expect.text.trim(),
        howToPass: _howToPass.text.trim(),
        usefulMaterialsNote: _materials.text.trim(),
        commonPitfalls: _pitfalls.text.trim(),
        status: _status,
        relatedTeachers: base?.relatedTeachers ?? const [],
        usefulLinks: _parseLinks(),
        relevanceDate: _relevance.text.trim().isEmpty
            ? null
            : _relevance.text.trim(),
        sectionOrder: _sectionOrder,
        catalogRowVersion: base?.catalogRowVersion ?? 1,
        profileRowVersion: base?.profileRowVersion ?? 1,
      );
      final saved = await widget.repository.save(next);
      if (!mounted) return;
      setState(() => _banner = 'Сохранено (catalog id=${saved.id}).');
      Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted) return;
      setState(() => _banner = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _moveSection(int index, int delta) {
    final next = index + delta;
    if (next < 0 || next >= _sectionOrder.length) return;
    setState(() {
      final copy = [..._sectionOrder];
      final tmp = copy[index];
      copy[index] = copy[next];
      copy[next] = tmp;
      _sectionOrder = normalizeSubjectCardSectionOrder(copy);
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _previewPayload();
    final offeringSelected = _selectedOffering != null;
    final hours = _selectedOffering?.hoursTotal ?? widget.hoursTotal;
    final credits = _selectedOffering?.credits ?? widget.credits;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.item == null ? 'Новая карточка предмета' : 'Карточка предмета',
        ),
        actions: [
          TextButton(
            onPressed: !_canWrite || _busy ? null : _save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_banner != null) Text(_banner!),
                const Text(
                  '16.1: текст / ссылки / порядок секций. '
                  'Изображения и файлы — Stage 16.2.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    helperText: 'Отображаемое имя; ключ — subject_id',
                  ),
                  enabled: _canWrite,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _short,
                  decoration: const InputDecoration(
                    labelText: 'Краткое описание',
                  ),
                  enabled: _canWrite,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'Подробное описание',
                  ),
                  enabled: _canWrite,
                  maxLines: 3,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _outcomes,
                  decoration: const InputDecoration(
                    labelText: 'Чему научится студент',
                  ),
                  enabled: _canWrite,
                  maxLines: 2,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _control,
                  decoration: const InputDecoration(
                    labelText: 'Форма контроля',
                  ),
                  enabled: _canWrite,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _department,
                  decoration: const InputDecoration(labelText: 'Кафедра'),
                  enabled: _canWrite,
                ),
                DropdownButtonFormField<String?>(
                  key: ValueKey('offering-$_selectedOfferingId'),
                  initialValue: _selectedOfferingId,
                  decoration: const InputDecoration(
                    labelText: 'Subject offering',
                    helperText:
                        'Часы/ЗЕ и преподаватели доступны только с offering',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Не выбран'),
                    ),
                    for (final o in _offerings)
                      DropdownMenuItem<String?>(
                        value: o.id,
                        child: Text(
                          o.displayName?.trim().isNotEmpty == true
                              ? o.displayName!
                              : o.id,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedOfferingId = value;
                      _bindOffering(_selectedOffering);
                    });
                  },
                ),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Часы / зачётные единицы',
                    helperText:
                        'SoT = curriculum_subjects через выбранный offering',
                  ),
                  child: Text(
                    offeringSelected && (hours != null || credits != null)
                        ? 'Часы: ${hours ?? '—'} · ЗЕ: ${credits ?? '—'}'
                        : 'Недоступно без выбранного offering',
                  ),
                ),
                TextField(
                  controller: _requirements,
                  decoration: const InputDecoration(labelText: 'Требования'),
                  enabled: _canWrite,
                  maxLines: 2,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _howToPass,
                  decoration: const InputDecoration(
                    labelText: 'Советы по подготовке',
                  ),
                  enabled: _canWrite,
                  maxLines: 2,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _expect,
                  decoration: const InputDecoration(labelText: 'Чего ожидать'),
                  enabled: _canWrite,
                  maxLines: 2,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _materials,
                  decoration: const InputDecoration(
                    labelText: 'Полезные материалы (текст)',
                  ),
                  enabled: _canWrite,
                ),
                TextField(
                  controller: _pitfalls,
                  decoration: const InputDecoration(
                    labelText: 'Типичные ошибки',
                  ),
                  enabled: _canWrite,
                ),
                TextField(
                  controller: _links,
                  decoration: const InputDecoration(
                    labelText: 'Ссылки (title|url на строку)',
                  ),
                  enabled: _canWrite,
                  maxLines: 3,
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  controller: _relevance,
                  decoration: const InputDecoration(
                    labelText: 'Дата актуальности (YYYY-MM-DD)',
                  ),
                  enabled: _canWrite,
                  onChanged: (_) => setState(() {}),
                ),
                DropdownButtonFormField<SubjectStatus>(
                  key: ValueKey(_status),
                  initialValue: _status,
                  decoration: const InputDecoration(labelText: 'Статус'),
                  items: const [
                    DropdownMenuItem(
                      value: SubjectStatus.draft,
                      child: Text('Черновик'),
                    ),
                    DropdownMenuItem(
                      value: SubjectStatus.published,
                      child: Text('Опубликовано'),
                    ),
                    DropdownMenuItem(
                      value: SubjectStatus.archived,
                      child: Text('В архиве'),
                    ),
                  ],
                  onChanged: !_canWrite
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _status = value);
                        },
                ),
                const SizedBox(height: 12),
                Text(
                  'Преподаватели / offering override',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (!offeringSelected)
                  const Text(
                    'Выберите offering, чтобы редактировать преподавателей '
                    'и override. Без offering список только для чтения.',
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in _selectedTeacherIds)
                        InputChip(
                          label: Text(_teacherLabels[id] ?? id),
                          onDeleted: !_canWrite
                              ? null
                              : () => setState(() {
                                    _selectedTeacherIds.remove(id);
                                  }),
                        ),
                    ],
                  ),
                  TextField(
                    controller: _teacherSearch,
                    enabled: _canWrite,
                    decoration: InputDecoration(
                      labelText: 'Найти преподавателя (имя / ID)',
                      helperText:
                          'Явный выбор offering обязателен; сохранение только по ID',
                      suffixIcon: IconButton(
                        onPressed: !_canWrite
                            ? null
                            : () => _searchTeachers(_teacherSearch.text),
                        icon: const Icon(Icons.search),
                      ),
                    ),
                    onChanged: (value) {
                      if (value.trim().length >= 2) {
                        _searchTeachers(value);
                      } else if (value.trim().isEmpty) {
                        setState(() => _teacherHits = const []);
                      }
                    },
                  ),
                  if (_teacherHits.isNotEmpty)
                    ...[
                      for (final teacher in _teacherHits)
                        ListTile(
                          dense: true,
                          title: Text(teacher.fullName),
                          subtitle: Text(teacher.id),
                          trailing: const Icon(Icons.add),
                          onTap: !_canWrite
                              ? null
                              : () {
                                  setState(() {
                                    if (!_selectedTeacherIds
                                        .contains(teacher.id)) {
                                      _selectedTeacherIds.add(teacher.id);
                                    }
                                    _teacherLabels[teacher.id] =
                                        teacher.fullName;
                                    _teacherHits = const [];
                                    _teacherSearch.clear();
                                  });
                                },
                        ),
                    ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : _saveTeachers,
                          child: const Text('Сохранить преподавателей'),
                        ),
                        TextButton(
                          onPressed: _busy ? null : _showOfferingVersions,
                          child: const Text('История override'),
                        ),
                      ],
                    ),
                  ),
                  TextField(
                    controller: _localDescription,
                    decoration: const InputDecoration(
                      labelText: 'local_description (override description)',
                    ),
                    enabled: _canWrite,
                    maxLines: 2,
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    controller: _semesterTips,
                    decoration: const InputDecoration(
                      labelText: 'semester_tips (override how_to_pass)',
                    ),
                    enabled: _canWrite,
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    controller: _teacherNote,
                    decoration: const InputDecoration(
                      labelText: 'teacher_specific_note (additive)',
                    ),
                    enabled: _canWrite,
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    controller: _assessmentNote,
                    decoration: const InputDecoration(
                      labelText: 'assessment_note (additive)',
                    ),
                    enabled: _canWrite,
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    controller: _workloadNote,
                    decoration: const InputDecoration(
                      labelText: 'workload_note (additive)',
                    ),
                    enabled: _canWrite,
                    onChanged: (_) => setState(() {}),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _busy ? null : _saveOverride,
                      child: const Text('Сохранить offering override'),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(
                  'Порядок секций',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                ...[
                  for (var i = 0; i < _sectionOrder.length; i++)
                    ListTile(
                      dense: true,
                      title: Text(
                        SubjectCardPayload.sectionTitleRu(_sectionOrder[i]),
                      ),
                      subtitle: Text(_sectionOrder[i]),
                      trailing: Wrap(
                        children: [
                          IconButton(
                            onPressed: !_canWrite || i == 0
                                ? null
                                : () => _moveSection(i, -1),
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            onPressed:
                                !_canWrite || i == _sectionOrder.length - 1
                                ? null
                                : () => _moveSection(i, 1),
                            icon: const Icon(Icons.arrow_downward),
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 360,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Preview',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                StudentSubjectCardPreview(payload: preview, height: 560),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String? get ifEmptyAsNull => trim().isEmpty ? null : trim();
}
