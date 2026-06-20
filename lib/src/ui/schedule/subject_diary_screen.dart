import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// calendar icon removed from header per chat style

import 'subject_diary/subject_diary.dart';
import '../../data/personal_diary_service.dart';
import 'package:file_picker/file_picker.dart' as fp;

enum DiaryViewMode { cards, grid }

class SubjectDiaryScreen extends StatefulWidget {
  final SubjectDiaryArgs args;

  SubjectDiaryScreen({
    super.key,
    String? subjectKey,
    SubjectDiaryArgs? args,
  }) : args = args ?? SubjectDiaryArgs.legacy(subjectKey ?? 'Предмет');

  String get subjectKey => args.displayTitle;

  @override
  State<SubjectDiaryScreen> createState() => _SubjectDiaryScreenState();
}

class _SubjectDiaryScreenState extends State<SubjectDiaryScreen> {
  final _repo = SubjectDiaryRepository.instance;
  final _diaryService = PersonalDiaryService();
  final _searchController = TextEditingController();
  final _assignmentDoneOverrides = <String, bool>{};
  final _taskStatusOverrides = <String, String>{};

  bool _loading = true;
  List<SubjectDiaryEntry> _all = [];
  List<PersonalDiaryAssignment> _assignments = [];
  List<PersonalDiaryTask> _personalTasks = [];

  late DateTime _focusedMonth;
  DateTime? _selectedDay; // null — все дни

  DiaryViewMode _view = DiaryViewMode.cards;

  SubjectDiaryArgs get _args => widget.args;
  String get _subjectKey => widget.args.displayTitle;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focusedMonth = DateTime(now.year, now.month);
    _selectedDay = null;
    _load();
    _subscribeDiaryRealtime(anchor: _focusedMonth);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _repo.listByArgs(_args);
    var assignments = const <PersonalDiaryAssignment>[];
    var tasks = const <PersonalDiaryTask>[];
    final offeringId = (_args.subjectOfferingId ?? '').trim();
    if (offeringId.isNotEmpty) {
      assignments = await _diaryService.loadPublishedAssignmentsForOffering(
        subjectOfferingId: offeringId,
        subjectTitle: _args.displayTitle,
      );
      tasks = await _diaryService.loadPersonalTasksForOfferings(
        offeringIds: [offeringId],
        subjectTitleByOffering: {offeringId: _args.displayTitle},
      );
    }
    if (!mounted) return;
    setState(() {
      _all = items;
      _assignments = assignments;
      _personalTasks = tasks;
      _loading = false;
    });
  }

  // ===== realtime =====
  RealtimeChannel? _diaryEntriesCh;
  RealtimeChannel? _diaryFilesCh;

  void _subscribeDiaryRealtime({required DateTime anchor}) {
    final client = Supabase.instance.client;
    _diaryEntriesCh = client
        .channel('public:subject_diary_entries')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'subject_diary_entries',
          callback: (_) => _reloadDiary(anchor: anchor),
        )
        .subscribe();

    _diaryFilesCh = client
        .channel('public:subject_diary_files')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'subject_diary_files',
          callback: (_) => _reloadDiary(anchor: anchor),
        )
        .subscribe();
  }

  void _disposeDiaryRealtime() {
    final client = Supabase.instance.client;
    if (_diaryEntriesCh != null) client.removeChannel(_diaryEntriesCh!);
    if (_diaryFilesCh != null) client.removeChannel(_diaryFilesCh!);
    _diaryEntriesCh = null;
    _diaryFilesCh = null;
  }

  Future<void> _reloadDiary({required DateTime anchor}) async {
    // Если дочерний экран попросил «помолчать», не рефрешим
    if (diaryRealtimeSuspended.value) return;
    await _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _disposeDiaryRealtime();
    super.dispose();
  }

  // === helpers ===

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  Map<DateTime, List<SubjectDiaryEntry>> get _groupedByDay {
    final map = <DateTime, List<SubjectDiaryEntry>>{};
    for (final e in _all) {
      final key = DateTime(e.date.year, e.date.month, e.date.day);
      (map[key] ??= []).add(e);
    }
    return map;
  }

  List<DateTime> get _daysSortedDesc {
    final keys = _groupedByDay.keys.toList();
    keys.sort((a, b) => b.compareTo(a));
    return keys;
  }

  List<DateTime> get _daysFiltered {
    final query = _searchController.text.trim().toLowerCase();
    final source = query.isEmpty
        ? _daysSortedDesc
        : _daysSortedDesc.where((day) {
            final entries = _groupedByDay[day] ?? const <SubjectDiaryEntry>[];
            return entries.any((entry) =>
                (entry.text ?? '').toLowerCase().contains(query) ||
                entry.files.any(
                    (file) => file.name.toLowerCase().contains(query)));
          }).toList();
    if (_selectedDay == null) return source;
    final k = DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day);
    return source.where((d) => _isSameDate(d, k)).toList();
  }

  bool _assignmentDone(PersonalDiaryAssignment assignment) {
    return _assignmentDoneOverrides[assignment.id] ?? assignment.completedByMe;
  }

  String _taskStatus(PersonalDiaryTask task) {
    return _taskStatusOverrides[task.id] ?? task.status;
  }

  String _nextTaskStatus(PersonalDiaryTask task) {
    switch (_taskStatus(task)) {
      case 'todo':
        return 'in_progress';
      case 'in_progress':
        return 'done';
      case 'done':
      default:
        return 'todo';
    }
  }

  // === deletion helpers ===

  Future<bool> _confirm(BuildContext context, String message) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Подтверждение', style: TextStyle(color: Colors.black)),
        content: Text(message, style: const TextStyle(color: Colors.black)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Удалить')),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _deleteDay(DateTime day) async {
    final ids = (_groupedByDay[day] ?? const <SubjectDiaryEntry>[]).map((e) => e.id).toList();
    for (final id in ids) {
      await _repo.deleteEntry(id);
    }
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Удалены записи за ${_fmtDate(day)}')));
    }
  }

  // === menu actions ===

  void _onMenuSelected(String key) {
    switch (key) {
      case 'today':
        setState(() {
          final now = DateTime.now();
          _selectedDay = DateTime(now.year, now.month, now.day);
          _focusedMonth = DateTime(now.year, now.month);
        });
        _load();
        break;
      case 'clear_filter':
        setState(() => _selectedDay = null);
        break;
      case 'view_cards':
        setState(() => _view = DiaryViewMode.cards);
        break;
      case 'view_grid':
        setState(() => _view = DiaryViewMode.grid);
        break;
      case 'all_notes':
        _openAllNotes();
        break;
      case 'all_conspects':
        _openAllConspects();
        break;
      case 'all_files':
        _openAllFiles();
        break;
    }
  }

  void _openAllNotes() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AllNotesScreen(
        subjectKey: _subjectKey,
        entriesFuture: _repo.listByArgs(_args),
      ),
    ));
  }

  void _openAllConspects() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AllConspectsGalleryScreen(
        subjectKey: _subjectKey,
        entriesFuture: _repo.listByArgs(_args),
      ),
    ));
  }

  void _openAllFiles() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AllFilesScreen(
        subjectKey: _subjectKey,
        entriesFuture: _repo.listByArgs(_args),
      ),
    ));
  }

  void _openNoteSheetForDay(DateTime day) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (b) => _InlineNewNoteSheet(
        subjectKey: _subjectKey,
        args: _args.copyWith(date: DateTime(day.year, day.month, day.day)),
        date: DateTime(day.year, day.month, day.day),
        onSaved: () async {
          Navigator.pop(b);
          await _load();
        },
      ),
    );
  }

  Future<void> _toggleAssignmentDone(PersonalDiaryAssignment assignment) async {
    final nextDone = !_assignmentDone(assignment);
    setState(() => _assignmentDoneOverrides[assignment.id] = nextDone);
    try {
      await _diaryService.setAssignmentDone(
        assignmentId: assignment.id,
        done: nextDone,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) await _load();
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) await _load();
    }
  }

  Future<void> _setTaskStatus(PersonalDiaryTask task, String status) async {
    setState(() => _taskStatusOverrides[task.id] = status);
    try {
      await _diaryService.updatePersonalTaskStatus(
        taskId: task.id,
        status: status,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) await _load();
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) await _load();
    }
  }

  Future<void> _openAssignmentDetails(PersonalDiaryAssignment assignment) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _SubjectAssignmentDetailsSheet(
        assignment: assignment,
        done: _assignmentDone(assignment),
        onToggleDone: () async {
          Navigator.pop(ctx);
          await _toggleAssignmentDone(assignment);
        },
      ),
    );
  }

  Future<void> _openTaskDetails(PersonalDiaryTask task) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _SubjectTaskDetailsSheet(
        task: task,
        statusOverride: _taskStatus(task),
        onSetStatus: (status) async {
          Navigator.pop(ctx);
          await _setTaskStatus(task, status);
        },
      ),
    );
  }

  Future<void> _openPersonalTaskForm() async {
    final offeringId = (_args.subjectOfferingId ?? '').trim();
    if (offeringId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Для этого предмета нет subject_offering_id')),
      );
      return;
    }
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _SubjectTaskFormSheet(
        subjectTitle: _args.displayTitle,
        onSave: ({
          required String title,
          String? description,
          DateTime? dueAt,
        }) async {
          await _diaryService.createPersonalTask(
            title: title,
            description: description,
            subjectOfferingId: offeringId,
            subjectTitle: _args.displayTitle,
            dueAt: dueAt,
          );
        },
      ),
    );
    if (saved == true) await _load();
  }

  // Правый верхний плюс: ветвление "Добавить запись"
  void _showAddEntrySheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final day = _selectedDay ?? DateTime.now();
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(.10),
                        shape: BoxShape.circle,
                      ),
                    child: Icon(Icons.add, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Добавить в дневник', style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800, color: Colors.black,
                      )),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _BranchTile(
                  icon: Icons.task_alt_rounded,
                  title: 'Личная задача',
                  subtitle: 'Задача будет привязана к этому предмету',
                  onTap: () {
                    Navigator.pop(ctx);
                    _openPersonalTaskForm();
                  },
                ),
                const SizedBox(height: 8),
                _BranchTile(
                  icon: Icons.sticky_note_2_outlined,
                  title: 'Заметка по предмету',
                  subtitle: 'Текстовая запись за выбранный день',
                  onTap: () {
                    Navigator.pop(ctx);
                    _openNoteSheetForDay(day);
                  },
                ),
                _BranchTile(
                  icon: Icons.photo_library_outlined,
                  title: 'Фото‑конспект',
                  subtitle: 'Выбрать фото и сохранить набор',
                  onTap: () async {
                    Navigator.pop(ctx);
                    final saved = await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SubjectPhotoConspectScreen(
                          subjectKey: _subjectKey,
                          args: _args.copyWith(
                            date: DateTime(day.year, day.month, day.day),
                          ),
                          date: DateTime(day.year, day.month, day.day),
                        ),
                      ),
                    );
                    if (saved == true) _load();
                  },
                ),
                _BranchTile(
                  icon: Icons.attach_file,
                  title: 'Файлы',
                  subtitle: 'Документы и другие вложения',
                  onTap: () async {
                    Navigator.pop(ctx);
                    // Переиспользуем существующую логику из дневного экрана
                    final result = await fp.FilePicker.platform.pickFiles(
                      allowMultiple: true, withData: true, type: fp.FileType.any,
                    );
                    if (result == null || result.files.isEmpty) return;
                    final files = <SubjectDiaryPickedFile>[];
                    for (final f in result.files) {
                      final bytes = f.bytes;
                      final name = f.name;
                      final mime = _detectMimePublic(name);
                      files.add(SubjectDiaryPickedFile(name: name, mime: mime, bytes: bytes));
                    }
                    await SubjectDiaryRepository.instance.addFilesPublic(
                      subjectKey: _subjectKey,
                      args: _args.copyWith(
                        date: DateTime(day.year, day.month, day.day),
                      ),
                      date: DateTime(day.year, day.month, day.day),
                      files: files,
                    );
                    if (mounted) {
                      await _load();
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Файлы добавлены')));
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // === build ===

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filteredAssignments = _assignments.where((assignment) {
      if (query.isEmpty) return true;
      return assignment.title.toLowerCase().contains(query) ||
          assignment.description.toLowerCase().contains(query);
    }).toList();
    final filteredTasks = _personalTasks.where((task) {
      if (query.isEmpty) return true;
      return task.title.toLowerCase().contains(query) ||
          (task.description ?? '').toLowerCase().contains(query);
    }).toList();

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 128,
            child: _ModelHeader(
              title: widget.subjectKey,
              subtitle: 'Дневник предмета',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AddButton(onTap: _showAddEntrySheet),
                  const SizedBox(width: 8),
                  _FancyMenuButton(onSelect: _onMenuSelected),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _DiarySearchField(
              controller: _searchController,
              hintText: 'Поиск по дневнику предмета',
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : CustomScrollView(
                      slivers: [
                        SliverToBoxAdapter(
                          child: _SubjectAssignmentsSection(
                            assignments: filteredAssignments,
                            tasks: filteredTasks,
                            assignmentDone: _assignmentDone,
                            taskStatus: _taskStatus,
                            onAssignmentTap: _openAssignmentDetails,
                            onToggleAssignment: _toggleAssignmentDone,
                            onTaskTap: _openTaskDetails,
                            onTaskStatusTap: (task) =>
                                _setTaskStatus(task, _nextTaskStatus(task)),
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 12)),
                        SliverToBoxAdapter(
                          child: _SubjectSectionTitle(
                            title: 'Записи',
                            subtitle: _daysFiltered.isEmpty
                                ? 'Записей пока нет.'
                                : 'Заметки, фото и файлы',
                          ),
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 8)),
                        if (_daysFiltered.isEmpty)
                          const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16),
                              child: _CompactEmptyCard(text: 'Записей пока нет.'),
                            ),
                          )
                        else if (_view == DiaryViewMode.cards)
                          _SliverDayCards(
                            days: _daysFiltered,
                            grouped: _groupedByDay,
                            onConfirmDeleteDay: (day) async {
                              final ok = await _confirm(context, 'Удалить все записи за ${_fmtDate(day)}?');
                              if (ok) await _deleteDay(day);
                              return ok;
                            },
                            onOpenDay: (day) => Navigator.of(context)
                                .push(MaterialPageRoute(
                                  builder: (_) => SubjectQuickNoteScreen(
                                    subjectKey: _subjectKey,
                                    args: _args.copyWith(date: day),
                                    date: day,
                                  ),
                                ))
                                .then((_) => _load()),
                          )
                        else
                          _SliverDayGrid(
                            days: _daysFiltered,
                            grouped: _groupedByDay,
                            onConfirmDeleteDay: (day) async {
                              final ok = await _confirm(context, 'Удалить все записи за ${_fmtDate(day)}?');
                              if (ok) await _deleteDay(day);
                              return ok;
                            },
                            onOpenDay: (day) => Navigator.of(context)
                                .push(MaterialPageRoute(
                                  builder: (_) => SubjectQuickNoteScreen(
                                    subjectKey: _subjectKey,
                                    args: _args.copyWith(date: day),
                                    date: day,
                                  ),
                                ))
                                .then((_) => _load()),
                          ),
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiarySearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  const _DiarySearchField({
    required this.controller,
    required this.hintText,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              ),
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _SubjectSectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _SubjectSectionTitle({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.black,
                ),
          ),
          if ((subtitle ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubjectAssignmentsSection extends StatelessWidget {
  final List<PersonalDiaryAssignment> assignments;
  final List<PersonalDiaryTask> tasks;
  final bool Function(PersonalDiaryAssignment assignment) assignmentDone;
  final String Function(PersonalDiaryTask task) taskStatus;
  final ValueChanged<PersonalDiaryAssignment> onAssignmentTap;
  final Future<void> Function(PersonalDiaryAssignment assignment)
      onToggleAssignment;
  final ValueChanged<PersonalDiaryTask> onTaskTap;
  final ValueChanged<PersonalDiaryTask> onTaskStatusTap;

  const _SubjectAssignmentsSection({
    required this.assignments,
    required this.tasks,
    required this.assignmentDone,
    required this.taskStatus,
    required this.onAssignmentTap,
    required this.onToggleAssignment,
    required this.onTaskTap,
    required this.onTaskStatusTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SubjectSectionTitle(
          title: 'Задания',
          subtitle:
              '${assignments.length} групповых • ${tasks.where((task) => !task.isDone).length} личных активных',
        ),
        const SizedBox(height: 8),
        if (assignments.isEmpty && tasks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: _CompactEmptyCard(text: 'Заданий по предмету пока нет.'),
          )
        else ...[
          ...assignments.map(
            (assignment) => _SubjectAssignmentCard(
              assignment: assignment,
              done: assignmentDone(assignment),
              onTap: () => onAssignmentTap(assignment),
              onToggle: () => onToggleAssignment(assignment),
            ),
          ),
          ...tasks.map(
            (task) => _SubjectTaskCard(
              task: task,
              statusOverride: taskStatus(task),
              onTap: () => onTaskTap(task),
              onStatusTap: () => onTaskStatusTap(task),
            ),
          ),
        ],
      ],
    );
  }
}

class _SubjectAssignmentCard extends StatelessWidget {
  final PersonalDiaryAssignment assignment;
  final bool done;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  const _SubjectAssignmentCard({
    required this.assignment,
    required this.done,
    required this.onTap,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return _SubjectTaskLikeCard(
      icon: Icons.assignment_outlined,
      title: assignment.title,
      subtitle: _subjectDueLabel(assignment.dueAt) ?? 'Задание группы',
      kind: 'Задание группы',
      status: done ? 'Выполнено' : 'Не выполнено',
      onTap: onTap,
      trailingText: done ? 'Снять' : 'Выполнить',
      onTrailingTap: onToggle,
    );
  }
}

class _SubjectTaskCard extends StatelessWidget {
  final PersonalDiaryTask task;
  final String statusOverride;
  final VoidCallback onTap;
  final VoidCallback onStatusTap;

  const _SubjectTaskCard({
    required this.task,
    required this.statusOverride,
    required this.onTap,
    required this.onStatusTap,
  });

  @override
  Widget build(BuildContext context) {
    return _SubjectTaskLikeCard(
      icon: Icons.task_alt_rounded,
      title: task.title,
      subtitle: _subjectDueLabel(task.dueAt) ?? task.subjectTitle,
      kind: 'Личная задача',
      status: _subjectTaskStatusLabel(statusOverride),
      onTap: onTap,
      trailingText: 'Статус',
      onTrailingTap: onStatusTap,
    );
  }
}

class _SubjectTaskLikeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String kind;
  final String status;
  final VoidCallback onTap;
  final String trailingText;
  final VoidCallback? onTrailingTap;

  const _SubjectTaskLikeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.kind,
    required this.status,
    required this.onTap,
    required this.trailingText,
    this.onTrailingTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: _subjectCardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Colors.black54),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _MiniBadge(text: kind),
                  const SizedBox(width: 8),
                  _MiniBadge(text: status, muted: true),
                  const Spacer(),
                  TextButton(
                    onPressed: onTrailingTap ?? onTap,
                    child: Text(trailingText),
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

class _MiniBadge extends StatelessWidget {
  final String text;
  final bool muted;

  const _MiniBadge({required this.text, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final color = muted ? Colors.black54 : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _CompactEmptyCard extends StatelessWidget {
  final String text;

  const _CompactEmptyCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _subjectCardDecoration(),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: Colors.black54),
      ),
    );
  }
}

class _SubjectTaskDetailsSheet extends StatelessWidget {
  final PersonalDiaryTask task;
  final String statusOverride;
  final Future<void> Function(String status) onSetStatus;

  const _SubjectTaskDetailsSheet({
    required this.task,
    required this.statusOverride,
    required this.onSetStatus,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '${task.subjectTitle} • ${_subjectTaskStatusLabel(statusOverride)}',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.black54, fontWeight: FontWeight.w700),
            ),
            if (task.dueAt != null) ...[
              const SizedBox(height: 4),
              Text(
                _subjectDueLabel(task.dueAt)!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              (task.description ?? '').trim().isEmpty
                  ? 'Описания нет.'
                  : task.description!,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.black87, height: 1.35),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => onSetStatus('todo'),
                    child: const Text('Todo'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => onSetStatus('in_progress'),
                    child: const Text('В работе'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => onSetStatus('done'),
                    child: const Text('Готово'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubjectAssignmentDetailsSheet extends StatelessWidget {
  final PersonalDiaryAssignment assignment;
  final bool done;
  final Future<void> Function() onToggleDone;

  const _SubjectAssignmentDetailsSheet({
    required this.assignment,
    required this.done,
    required this.onToggleDone,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              assignment.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '${assignment.subjectTitle} • Задание группы',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.black54, fontWeight: FontWeight.w700),
            ),
            if (assignment.dueAt != null) ...[
              const SizedBox(height: 4),
              Text(
                _subjectDueLabel(assignment.dueAt)!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              assignment.description.trim().isEmpty
                  ? 'Описания нет.'
                  : assignment.description,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.black87, height: 1.35),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onToggleDone,
                icon: Icon(
                  done
                      ? Icons.undo_rounded
                      : Icons.check_circle_outline_rounded,
                ),
                label: Text(
                  done
                      ? 'Отметить как не выполнено'
                      : 'Отметить как выполнено',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubjectTaskFormSheet extends StatefulWidget {
  final String subjectTitle;
  final Future<void> Function({
    required String title,
    String? description,
    DateTime? dueAt,
  }) onSave;

  const _SubjectTaskFormSheet({
    required this.subjectTitle,
    required this.onSave,
  });

  @override
  State<_SubjectTaskFormSheet> createState() => _SubjectTaskFormSheetState();
}

class _SubjectTaskFormSheetState extends State<_SubjectTaskFormSheet> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime? _dueAt;
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * .86;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 6, 18, 18 + bottomInset),
          child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Личная задача',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.subjectTitle,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: Colors.black54, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _titleController,
                decoration: _subjectInputDecoration('Название'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _descriptionController,
                minLines: 2,
                maxLines: 4,
                decoration: _subjectInputDecoration('Описание, если нужно'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _pickDueDate,
                icon: const Icon(Icons.event_outlined),
                label: Text(_dueAt == null
                    ? 'Добавить дедлайн'
                    : 'Дедлайн: ${_subjectFmtDate(_dueAt!)}'),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Сохраняем...' : 'Создать задачу'),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueAt ?? DateTime(now.year, now.month, now.day),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      helpText: 'Дедлайн задачи',
      cancelText: 'Отмена',
      confirmText: 'Выбрать',
    );
    if (picked != null) setState(() => _dueAt = picked);
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Введите название задачи')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        title: title,
        description: _descriptionController.text.trim(),
        dueAt: _dueAt,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать личную задачу')),
      );
    }
  }
}

BoxDecoration _subjectCardDecoration() {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(.06),
        blurRadius: 12,
        offset: const Offset(0, 3),
      ),
    ],
  );
}

InputDecoration _subjectInputDecoration(String label) {
  return InputDecoration(
    labelText: label,
    filled: true,
    fillColor: const Color(0xFFF6F7FB),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: BorderSide.none,
    ),
  );
}

String _subjectFmtDate(DateTime date) {
  return '${date.day.toString().padLeft(2, '0')}.'
      '${date.month.toString().padLeft(2, '0')}.'
      '${date.year}';
}

String? _subjectDueLabel(DateTime? date) {
  if (date == null) return null;
  return 'до ${_subjectFmtDate(date)}';
}

String _subjectTaskStatusLabel(String status) {
  switch (status) {
    case 'in_progress':
      return 'В работе';
    case 'done':
      return 'Готово';
    case 'todo':
    default:
      return 'Нужно сделать';
  }
}

/// ====== списки дней

class _SliverDayCards extends StatelessWidget {
  final List<DateTime> days;
  final Map<DateTime, List<SubjectDiaryEntry>> grouped;
  final ValueChanged<DateTime> onOpenDay;
  final Future<bool> Function(DateTime day) onConfirmDeleteDay;

  const _SliverDayCards({
    required this.days,
    required this.grouped,
    required this.onOpenDay,
    required this.onConfirmDeleteDay,
  });

  @override
  Widget build(BuildContext context) {
    return SliverList.separated(
      itemCount: days.length,
      itemBuilder: (ctx, i) {
        final day = days[i];
        final entries = grouped[day] ?? const <SubjectDiaryEntry>[];
        final key = ValueKey('day-${day.year}-${day.month}-${day.day}');
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Dismissible(
            key: key,
            direction: DismissDirection.endToStart,
            background: _swipeBg(),
            confirmDismiss: (_) => onConfirmDeleteDay(day),
            child: _DayCard(day: day, entries: entries, onOpen: () => onOpenDay(day)),
          ),
        );
      },
      separatorBuilder: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _swipeBg() => Container(
        decoration: BoxDecoration(
          color: const Color(0xFFE53935),
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      );
}

class _SliverDayGrid extends StatelessWidget {
  final List<DateTime> days;
  final Map<DateTime, List<SubjectDiaryEntry>> grouped;
  final ValueChanged<DateTime> onOpenDay;
  final Future<bool> Function(DateTime day) onConfirmDeleteDay;

  const _SliverDayGrid({
    required this.days,
    required this.grouped,
    required this.onOpenDay,
    required this.onConfirmDeleteDay,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.15,
        ),
        delegate: SliverChildBuilderDelegate(
          (ctx, i) {
            final day = days[i];
            final entries = grouped[day] ?? const <SubjectDiaryEntry>[];
            final key = ValueKey('grid-day-${day.year}-${day.month}-${day.day}');
            return Dismissible(
              key: key,
              direction: DismissDirection.endToStart,
              background: _swipeBg(),
              confirmDismiss: (_) => onConfirmDeleteDay(day),
              child: _DayTile(day: day, entries: entries, onOpen: () => onOpenDay(day)),
            );
          },
          childCount: days.length,
        ),
      ),
    );
  }

  Widget _swipeBg() => Container(
        decoration: BoxDecoration(
          color: const Color(0xFFE53935),
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      );
}

class _DayCard extends StatelessWidget {
  final DateTime day;
  final List<SubjectDiaryEntry> entries;
  final VoidCallback onOpen;

  const _DayCard({required this.day, required this.entries, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = SubjectDiaryRepository.instance;

    final allImages = <SubjectDiaryFile>[];
    final notes = <String>[];
    for (final e in entries) {
      allImages.addAll(e.files.where((f) => f.isImage));
      if ((e.text ?? '').trim().isNotEmpty) notes.add(e.text!.trim());
    }
    final thumbs = allImages.take(3).toList();
    final textPreview = notes.isEmpty ? 'Без заметок' : notes.first;

    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))],
        ),
        child: Row(
          children: [
            _ThumbCollage(thumbs: thumbs, repo: repo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_fmtDate(day),
                      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800, color: Colors.black)),
                  const SizedBox(height: 4),
                  Text(
                    textPreview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.black.withOpacity(.75)),
                  ),
                  const SizedBox(height: 6),
                  Text(_metaLine(entries), style: theme.textTheme.labelSmall?.copyWith(color: Colors.black54)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: Colors.black54),
          ],
        ),
      ),
    );
  }

  String _metaLine(List<SubjectDiaryEntry> entries) {
    final photos = entries.fold<int>(0, (s, e) => s + e.files.where((f) => f.isImage).length);
    final files = entries.fold<int>(0, (s, e) => s + e.files.length);
    final notes = entries.where((e) => (e.text ?? '').trim().isNotEmpty).length;
    final parts = <String>[];
    if (notes > 0) parts.add('Заметок: $notes');
    if (photos > 0) parts.add('Фото: $photos');
    if (files - photos > 0) parts.add('Файлы: ${files - photos}');
    return parts.isEmpty ? 'Пусто' : parts.join(' • ');
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
}

class _DayTile extends StatelessWidget {
  final DateTime day;
  final List<SubjectDiaryEntry> entries;
  final VoidCallback onOpen;

  const _DayTile({required this.day, required this.entries, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final repo = SubjectDiaryRepository.instance;

    final images = <SubjectDiaryFile>[];
    for (final e in entries) {
      images.addAll(e.files.where((f) => f.isImage));
    }
    final thumbs = images.take(1).toList();

    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ThumbCollage(thumbs: thumbs, repo: repo, big: true),
            const SizedBox(height: 8),
            Text(
              '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}',
              style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              _metaLine(entries),
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.black.withOpacity(.7)),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            const Align(
              alignment: Alignment.bottomRight,
              child: Icon(Icons.chevron_right_rounded, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  String _metaLine(List<SubjectDiaryEntry> entries) {
    final photos = entries.fold<int>(0, (s, e) => s + e.files.where((f) => f.isImage).length);
    final files = entries.fold<int>(0, (s, e) => s + e.files.length);
    final notes = entries.where((e) => (e.text ?? '').trim().isNotEmpty).length;
    final parts = <String>[];
    if (notes > 0) parts.add('Заметок: $notes');
    if (photos > 0) parts.add('Фото: $photos');
    if (files - photos > 0) parts.add('Файлы: ${files - photos}');
    return parts.isEmpty ? 'Пусто' : parts.join(' • ');
  }
}

class _ThumbCollage extends StatelessWidget {
  final List<SubjectDiaryFile> thumbs; // image/*
  final SubjectDiaryRepository repo;
  final bool big;
  const _ThumbCollage({required this.thumbs, required this.repo, this.big = false});

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    final size = big ? 88.0 : 56.0;

    if (thumbs.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withOpacity(.08),
          borderRadius: radius,
        ),
        child: Icon(Icons.insert_drive_file_outlined, color: Theme.of(context).colorScheme.primary),
      );
    }

    if (thumbs.length == 1) {
      final b = repo.getLocalThumb(thumbs[0].url);
      return ClipRRect(
        borderRadius: radius,
        child: b != null
            ? Image.memory(b, width: size, height: size, fit: BoxFit.cover)
            : Container(width: size, height: size, color: const Color(0x11000000)),
      );
    }

    final boxes = <Widget>[];
    for (var i = 0; i < thumbs.length && i < 3; i++) {
      final b = repo.getLocalThumb(thumbs[i].url);
      boxes.add(Expanded(
        child: ClipRRect(
          borderRadius: i == 0
              ? BorderRadius.only(topLeft: radius.topLeft, bottomLeft: radius.bottomLeft)
              : (i == thumbs.length - 1
                  ? BorderRadius.only(topRight: radius.topRight, bottomRight: radius.bottomRight)
                  : BorderRadius.zero),
          child: SizedBox(
            height: size,
            child: b != null ? Image.memory(b, fit: BoxFit.cover) : const ColoredBox(color: Color(0x11000000)),
          ),
        ),
      ));
    }

    return SizedBox(width: size, height: size, child: Row(children: boxes));
  }
}

/// ===== агрегаторы

class AllConspectsGalleryScreen extends StatelessWidget {
  final String subjectKey;
  final Future<List<SubjectDiaryEntry>> entriesFuture;
  const AllConspectsGalleryScreen({super.key, required this.subjectKey, required this.entriesFuture});

  @override
  Widget build(BuildContext context) {
    final repo = SubjectDiaryRepository.instance;
    return Scaffold(
      body: Column(
        children: [
          SizedBox(
            height: 128,
            child: _ModelHeader(title: 'Все конспекты', subtitle: subjectKey),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<SubjectDiaryEntry>>(
              future: entriesFuture,
              builder: (ctx, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final images = <SubjectDiaryFile>[];
                for (final e in snap.data!) {
                  images.addAll(e.files.where((f) => f.isImage));
                }
                if (images.isEmpty) return const Center(child: Text('Нет фотографий конспектов'));
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1,
                  ),
                  itemCount: images.length,
                  itemBuilder: (ctx, i) {
                    final f = images[i];
                    final bytes = repo.getLocalThumb(f.url);
                    return InkWell(
                      onTap: bytes == null
                          ? null
                          : () {
                              final imageBytes = bytes;
                              showDialog(
                                context: ctx,
                                builder: (_) => Dialog(
                                  backgroundColor: Colors.black,
                                  insetPadding: const EdgeInsets.all(12),
                                  child: InteractiveViewer(
                                    child: Image.memory(imageBytes, fit: BoxFit.contain),
                                  ),
                                ),
                              );
                            },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: bytes != null ? Image.memory(bytes, fit: BoxFit.cover) : const ColoredBox(color: Color(0x11000000)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class AllFilesScreen extends StatelessWidget {
  final String subjectKey;
  final Future<List<SubjectDiaryEntry>> entriesFuture;
  const AllFilesScreen({super.key, required this.subjectKey, required this.entriesFuture});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          SizedBox(height: 128, child: _ModelHeader(title: 'Все файлы', subtitle: subjectKey)),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<SubjectDiaryEntry>>(
              future: entriesFuture,
              builder: (ctx, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final files = <SubjectDiaryFile>[];
                for (final e in snap.data!) {
                  files.addAll(e.files);
                }
                if (files.isEmpty) return const Center(child: Text('Файлы не найдены'));
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  itemCount: files.length,
                  separatorBuilder: (_, __) => const Divider(height: 12),
                  itemBuilder: (ctx, i) {
                    final f = files[i];
                    return Row(
                      children: [
                        Icon(f.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined),
                        const SizedBox(width: 10),
                        Expanded(child: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 8),
                        Text(_fmtSize(f.size), style: theme.textTheme.labelSmall?.copyWith(color: Colors.black54)),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} КБ';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} МБ';
  }
}

class AllNotesScreen extends StatelessWidget {
  final String subjectKey;
  final Future<List<SubjectDiaryEntry>> entriesFuture;
  const AllNotesScreen({super.key, required this.subjectKey, required this.entriesFuture});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          SizedBox(height: 128, child: _ModelHeader(title: 'Все заметки', subtitle: subjectKey)),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<SubjectDiaryEntry>>(
              future: entriesFuture,
              builder: (ctx, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final notes = snap.data!
                    .where((e) => (e.text ?? '').trim().isNotEmpty)
                    .toList()
                  ..sort((a, b) => b.date.compareTo(a.date));
                if (notes.isEmpty) return const Center(child: Text('Заметок пока нет'));
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  itemCount: notes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) {
                    final e = notes[i];
                    final d =
                        '${e.date.day.toString().padLeft(2, '0')}.${e.date.month.toString().padLeft(2, '0')}.${e.date.year}';
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(d, style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 6),
                          Text(e.text!.trim(), style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// ===== единая шапка

class _ModelHeader extends StatelessWidget {
  final String title;
  final String? subtitle; // игнорируется — название только
  final Widget? trailing; // игнорируется
  const _ModelHeader({required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Colors.white, theme.colorScheme.primary.withOpacity(0.06), theme.colorScheme.primary.withOpacity(0.12)],
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(
            children: [
              Positioned(left: -40, top: -20, child: _GlowCircle(diameter: 140, color: theme.colorScheme.primary.withOpacity(0.10))),
              Positioned(right: -30, bottom: -30, child: _GlowCircle(diameter: 160, color: Colors.white.withOpacity(0.55))),
            ],
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Align(
              alignment: const Alignment(-1, 0.25),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const _RoundBackButton(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Builder(builder: (context) {
                      final base = Theme.of(context).textTheme.headlineSmall?.fontSize ?? 24.0;
                      final titleSize = base / 2 + 6; // еще +2
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontSize: titleSize,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.black,
                                  height: 1.05,
                                  shadows: [Shadow(color: Colors.black.withOpacity(0.05), offset: const Offset(0, 2), blurRadius: 3)],
                                ),
                          ),
                          if ((subtitle ?? '').isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              subtitle!,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.black54,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ],
                      );
                    }),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ] else ...[
                    const SizedBox(width: 48),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double diameter;
  final Color color;
  const _GlowCircle({required this.diameter, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// Круглая кнопка «Назад» как в чате
class _RoundBackButton extends StatelessWidget {
  const _RoundBackButton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 3)),
        ],
      ),
      child: IconButton(
        tooltip: 'Назад',
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

// Локальная версия формы новой заметки (копия по месту, чтобы не тянуть приватный виджет)
class _InlineNewNoteSheet extends StatefulWidget {
  final String subjectKey;
  final SubjectDiaryArgs? args;
  final DateTime date;
  final VoidCallback onSaved;
  const _InlineNewNoteSheet({
    required this.subjectKey,
    this.args,
    required this.date,
    required this.onSaved,
  });

  @override
  State<_InlineNewNoteSheet> createState() => _InlineNewNoteSheetState();
}

class _InlineNewNoteSheetState extends State<_InlineNewNoteSheet> {
  final _ctrl = TextEditingController();
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Заметка по предмету',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800, color: Colors.black,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              maxLines: null,
              minLines: 6,
              decoration: InputDecoration(
                hintText: 'Заметка...',
                filled: true,
                fillColor: theme.colorScheme.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width:16, height:16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Сохранить'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Пустой текст')));
      return;
    }
    setState(() => _saving = true);
    try {
      await SubjectDiaryRepository.instance.addText(
        subjectKey: widget.subjectKey,
        args: widget.args,
        date: widget.date,
        text: text,
      );
      if (!mounted) return;
      widget.onSaved();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

String _detectMimePublic(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.gif')) return 'image/gif';
  if (n.endsWith('.webp')) return 'image/webp';
  if (n.endsWith('.pdf')) return 'application/pdf';
  if (n.endsWith('.doc')) return 'application/msword';
  if (n.endsWith('.docx')) return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  if (n.endsWith('.xls')) return 'application/vnd.ms-excel';
  if (n.endsWith('.xlsx')) return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  if (n.endsWith('.ppt')) return 'application/vnd.ms-powerpoint';
  if (n.endsWith('.pptx')) return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
  if (n.endsWith('.txt')) return 'text/plain';
  if (n.endsWith('.csv')) return 'text/csv';
  if (n.endsWith('.zip')) return 'application/zip';
  return 'application/octet-stream';
}

class _BranchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _BranchTile({required this.icon, required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))],
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(.10), shape: BoxShape.circle),
              child: Icon(icon, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: Colors.black)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: Colors.black.withOpacity(.64))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.black54),
          ],
        ),
      ),
    );
  }
}

class _FancyMenuButton extends StatelessWidget {
  final ValueChanged<String> onSelect;
  const _FancyMenuButton({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => _open(context),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        child: const Icon(Icons.more_horiz),
      ),
    );
  }

  void _open(BuildContext context) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FancyMenuItem(
                icon: Icons.note_alt_outlined,
                title: 'Все заметки',
                onTap: () { Navigator.pop(ctx); onSelect('all_notes'); },
              ),
              _FancyMenuItem(
                icon: Icons.photo_library_outlined,
                title: 'Все конспекты',
                onTap: () { Navigator.pop(ctx); onSelect('all_conspects'); },
              ),
              _FancyMenuItem(
                icon: Icons.folder_open,
                title: 'Все файлы',
                onTap: () { Navigator.pop(ctx); onSelect('all_files'); },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FancyMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const _FancyMenuItem({required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 3))],
        ),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(color: theme.colorScheme.primary.withOpacity(.10), shape: BoxShape.circle),
              child: Icon(icon, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: Colors.black)),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.black54),
          ],
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 10, offset: const Offset(0, 3)),
          ],
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}
