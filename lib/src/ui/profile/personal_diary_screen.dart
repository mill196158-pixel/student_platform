import 'package:flutter/material.dart';

import '../../data/personal_diary_service.dart';
import '../schedule/subject_diary/subject_diary.dart';
import '../schedule/subject_diary_screen.dart';

class PersonalDiaryScreen extends StatefulWidget {
  const PersonalDiaryScreen({super.key});

  @override
  State<PersonalDiaryScreen> createState() => _PersonalDiaryScreenState();
}

class _PersonalDiaryScreenState extends State<PersonalDiaryScreen> {
  final _service = PersonalDiaryService();
  final _searchController = TextEditingController();
  final _assignmentDoneOverrides = <String, bool>{};
  final _taskStatusOverrides = <String, String>{};
  late Future<PersonalDiaryData> _future = _loadWithCache();

  Future<PersonalDiaryData> _loadWithCache() async {
    final cached = await _service.loadCached();
    if (cached != null) {
      _refreshSilently();
      return cached;
    }
    return _service.loadAndCache();
  }

  Future<void> _refresh() async {
    setState(() => _future = _service.loadAndCache());
    await _future;
  }

  void _refreshSilently() {
    _service.loadAndCache().then((fresh) {
      if (!mounted) return;
      setState(() => _future = Future<PersonalDiaryData>.value(fresh));
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 390;
    return Scaffold(
      backgroundColor: const Color(0xFFFBFAFF),
      body: FutureBuilder<PersonalDiaryData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data;
          if (data == null) {
            return const Center(child: Text('Не удалось загрузить дневник'));
          }

          final query = _searchController.text.trim().toLowerCase();
          final diarySubjects = data.subjects
              .where((subject) => _matchesSubject(subject, query))
              .toList();
          final activeDiarySubjects = diarySubjects
              .where(
                  (subject) => subject.entryCount > 0 || subject.fileCount > 0)
              .toList();
          final latestEntries = data.latestEntries
              .where((entry) => _matchesLatestEntry(entry, query))
              .toList();
          final upcomingItems = _buildUpcomingItems(data)
              .where((item) => _matchesUpcomingItem(item, query))
              .toList();
          final hiddenDoneItems = _buildDoneUpcomingItems(data)
              .where((item) => _matchesUpcomingItem(item, query))
              .toList();

          return Column(
            children: [
              _DiaryHeader(
                onAdd: () => _openAddEntryPicker(data),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 12 : 16,
                      14,
                      compact ? 12 : 16,
                      24,
                    ),
                    children: [
                      _DiarySummaryCard(data: data),
                      const SizedBox(height: 10),
                      _SearchField(
                        controller: _searchController,
                        hintText: 'Поиск по дневнику',
                        onChanged: (_) => setState(() {}),
                      ),
                      SizedBox(height: compact ? 14 : 18),
                      _SectionTitle(
                        title: 'Ближайшие задания',
                        subtitle:
                            '${data.totalAssignments} групповых • ${data.personalTasksActive} личных активных',
                      ),
                      const SizedBox(height: 8),
                      if (upcomingItems.isEmpty)
                        const _EmptyCard(
                          text: 'Активных ближайших заданий пока нет.',
                        )
                      else
                        _CollapsibleTasksSection(
                          title: 'Активные ближайшие',
                          subtitle: '${upcomingItems.length} скрыто',
                          icon: Icons.upcoming_rounded,
                          items: upcomingItems,
                          itemBuilder: _buildUpcomingCard,
                        ),
                      if (hiddenDoneItems.isNotEmpty)
                        _CollapsibleTasksSection(
                          title: 'Выполненные',
                          subtitle: '${hiddenDoneItems.length} скрыто',
                          icon: Icons.done_all_rounded,
                          items: hiddenDoneItems,
                          itemBuilder: _buildUpcomingCard,
                        ),
                      SizedBox(height: compact ? 14 : 18),
                      _SectionTitle(
                        title: 'Последние записи',
                        subtitle: latestEntries.isEmpty
                            ? null
                            : 'Только реальные записи',
                      ),
                      const SizedBox(height: 8),
                      if (latestEntries.isEmpty)
                        const _EmptyCard(
                          text:
                              'Записей пока нет. Открой предмет и добавь первую заметку.',
                        )
                      else
                        ...latestEntries.map(_LatestEntryCard.new),
                      if (activeDiarySubjects.isNotEmpty ||
                          diarySubjects.isNotEmpty) ...[
                        SizedBox(height: compact ? 14 : 18),
                        _CollapsibleSubjectsSection(
                          title: 'Активные дневники',
                          subtitle: activeDiarySubjects.isEmpty
                              ? 'Записей пока нет'
                              : '${activeDiarySubjects.length} с записями',
                          icon: Icons.edit_note_rounded,
                          subjects: activeDiarySubjects,
                          onTap: _openSubjectDiary,
                        ),
                        _CollapsibleSubjectsSection(
                          title: 'Предметы семестра',
                          subtitle: '${diarySubjects.length} предметов',
                          icon: Icons.menu_book_outlined,
                          subjects: diarySubjects,
                          onTap: _openSubjectDiary,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<_UpcomingDiaryItem> _buildUpcomingItems(PersonalDiaryData data) {
    final items = <_UpcomingDiaryItem>[
      ...data.upcomingAssignments.map(_UpcomingDiaryItem.groupAssignment),
      ...data.upcomingPersonalTasks.map(_UpcomingDiaryItem.personalTask),
    ].where((item) => !_isUpcomingItemDone(item)).toList()
      ..sort((a, b) {
        final aDue = a.dueAt;
        final bDue = b.dueAt;
        if (aDue != null && bDue != null) return aDue.compareTo(bDue);
        if (aDue != null) return -1;
        if (bDue != null) return 1;
        return a.createdAt.compareTo(b.createdAt);
      });
    return items.take(8).toList();
  }

  List<_UpcomingDiaryItem> _buildDoneUpcomingItems(PersonalDiaryData data) {
    final items = <_UpcomingDiaryItem>[
      ...data.publishedAssignments.map(_UpcomingDiaryItem.groupAssignment),
      ...data.personalTasks.map(_UpcomingDiaryItem.personalTask),
    ].where(_isUpcomingItemDone).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items.take(8).toList();
  }

  PersonalDiaryData _dataWithCreatedTask(
    PersonalDiaryData data,
    PersonalDiaryTask task,
  ) {
    final tasks = [
      task,
      ...data.personalTasks.where((existing) => existing.id != task.id),
    ]..sort(_comparePersonalTasksForUi);
    final upcomingTasks = tasks.take(5).toList();

    return PersonalDiaryData(
      academicContext: data.academicContext,
      availableSemesters: data.availableSemesters,
      selectedSemesterNumber: data.selectedSemesterNumber,
      allSubjects: data.allSubjects
          .map((subject) => _subjectWithCreatedTask(subject, task))
          .toList(),
      subjects: data.subjects
          .map((subject) => _subjectWithCreatedTask(subject, task))
          .toList(),
      latestEntries: data.latestEntries,
      publishedAssignments: data.publishedAssignments,
      upcomingAssignments: data.upcomingAssignments,
      personalTasks: tasks,
      upcomingPersonalTasks: upcomingTasks,
      totalEntries: data.totalEntries,
      totalFiles: data.totalFiles,
      totalAssignments: data.totalAssignments,
      pendingAssignmentsCount: data.pendingAssignmentsCount,
      completedAssignmentsCount: data.completedAssignmentsCount,
      personalTasksTotal: tasks.length,
      personalTasksActive: tasks.where((item) => !item.isDone).length,
      personalTasksDone: tasks.where((item) => item.isDone).length,
    );
  }

  PersonalDiarySubject _subjectWithCreatedTask(
    PersonalDiarySubject subject,
    PersonalDiaryTask task,
  ) {
    if ((task.subjectOfferingId ?? '') != subject.subjectOfferingId) {
      return subject;
    }
    return PersonalDiarySubject(
      subjectOfferingId: subject.subjectOfferingId,
      subjectId: subject.subjectId,
      title: subject.title,
      groupId: subject.groupId,
      semesterNumber: subject.semesterNumber,
      entryCount: subject.entryCount,
      fileCount: subject.fileCount,
      assignmentCount: subject.assignmentCount,
      incompleteAssignmentCount: subject.incompleteAssignmentCount,
      personalTaskCount: subject.personalTaskCount + 1,
      activePersonalTaskCount:
          subject.activePersonalTaskCount + (task.isDone ? 0 : 1),
      latestEntryDate: subject.latestEntryDate,
      latestPreview: subject.latestPreview,
    );
  }

  int _comparePersonalTasksForUi(
    PersonalDiaryTask a,
    PersonalDiaryTask b,
  ) {
    final aDue = a.dueAt;
    final bDue = b.dueAt;
    if (aDue != null && bDue != null) return aDue.compareTo(bDue);
    if (aDue != null) return -1;
    if (bDue != null) return 1;
    return b.createdAt.compareTo(a.createdAt);
  }

  Widget _buildUpcomingCard(_UpcomingDiaryItem item) {
    final assignment = item.assignment;
    if (assignment != null) {
      return _AssignmentDiaryCard(
        assignment: assignment,
        done: _assignmentDone(assignment),
        onTap: () => _openAssignmentDetails(assignment),
        onToggleDone: () => _toggleAssignmentDone(assignment),
      );
    }
    final task = item.task!;
    return _PersonalTaskCard(
      task: task,
      statusOverride: _taskStatus(task),
      onTap: () => _openPersonalTaskDetails(task),
      onChangeStatus: () => _setPersonalTaskStatus(task, _nextTaskStatus(task)),
    );
  }

  bool _isUpcomingItemDone(_UpcomingDiaryItem item) {
    final assignment = item.assignment;
    if (assignment != null) return _assignmentDone(assignment);
    return _taskStatus(item.task!) == 'done';
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

  bool _matchesSubject(PersonalDiarySubject subject, String query) {
    if (query.isEmpty) return true;
    return subject.title.toLowerCase().contains(query) ||
        (subject.latestPreview ?? '').toLowerCase().contains(query);
  }

  bool _matchesLatestEntry(PersonalDiaryLatestEntry entry, String query) {
    if (query.isEmpty) return true;
    return entry.subjectTitle.toLowerCase().contains(query) ||
        (entry.preview ?? '').toLowerCase().contains(query);
  }

  bool _matchesUpcomingItem(_UpcomingDiaryItem item, String query) {
    if (query.isEmpty) return true;
    return item.title.toLowerCase().contains(query) ||
        item.subjectTitle.toLowerCase().contains(query) ||
        (item.description ?? '').toLowerCase().contains(query);
  }

  Future<void> _openSubjectDiary(PersonalDiarySubject subject) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SubjectDiaryScreen(args: subject.toDiaryArgs()),
      ),
    );
    if (mounted) _refresh();
  }

  Future<void> _toggleAssignmentDone(PersonalDiaryAssignment assignment) async {
    final nextDone = !_assignmentDone(assignment);
    setState(() => _assignmentDoneOverrides[assignment.id] = nextDone);
    try {
      await _service.setAssignmentDone(
        assignmentId: assignment.id,
        done: nextDone,
      );
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) await _refresh();
    } catch (_) {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) await _refresh();
    }
  }

  Future<void> _setPersonalTaskStatus(
    PersonalDiaryTask task,
    String status,
  ) async {
    setState(() => _taskStatusOverrides[task.id] = status);
    try {
      await _service.updatePersonalTaskStatus(taskId: task.id, status: status);
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) await _refresh();
    } catch (_) {
      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) await _refresh();
    }
  }

  Future<void> _openAssignmentDetails(
      PersonalDiaryAssignment assignment) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return _AssignmentDetailsSheet(
          assignment: assignment,
          done: _assignmentDone(assignment),
          onToggleDone: () async {
            Navigator.of(ctx).pop();
            await _toggleAssignmentDone(assignment);
          },
        );
      },
    );
  }

  Future<void> _openPersonalTaskDetails(PersonalDiaryTask task) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return _PersonalTaskDetailsSheet(
          task: task,
          statusOverride: _taskStatus(task),
          onSetStatus: (status) async {
            Navigator.of(ctx).pop();
            await _setPersonalTaskStatus(task, status);
          },
        );
      },
    );
  }

  Future<void> _openAddEntryPicker(PersonalDiaryData data) async {
    if (data.allSubjects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Предметы для записи пока не найдены')),
      );
      return;
    }

    final mode = await showModalBottomSheet<_AddEntryMode>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        final maxHeight = MediaQuery.sizeOf(ctx).height * .82;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Добавить в дневник',
                    style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Личные задачи остаются только в дневнике и не попадают в чат.',
                    style: Theme.of(ctx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  _AddModeTile(
                    icon: Icons.calendar_month_rounded,
                    title: 'Календарь дневника',
                    subtitle: 'Пары, записи и задания по датам',
                    onTap: () =>
                        Navigator.pop(ctx, _AddEntryMode.diaryCalendar),
                  ),
                  const SizedBox(height: 8),
                  _AddModeTile(
                    icon: Icons.task_alt_rounded,
                    title: 'Личная задача',
                    subtitle: 'Название, предмет и дедлайн по желанию',
                    onTap: () => Navigator.pop(ctx, _AddEntryMode.personalTask),
                  ),
                  const SizedBox(height: 8),
                  _AddModeTile(
                    icon: Icons.today_outlined,
                    title: 'Заметка',
                    subtitle: 'Выбрать предмет и сразу написать за сегодня',
                    onTap: () => Navigator.pop(ctx, _AddEntryMode.todaySubject),
                  ),
                  const SizedBox(height: 8),
                  _AddModeTile(
                    icon: Icons.calendar_month_outlined,
                    title: 'Фото-конспект',
                    subtitle: 'Предмет плюс дата через календарь',
                    onTap: () => Navigator.pop(ctx, _AddEntryMode.datedSubject),
                  ),
                  const SizedBox(height: 8),
                  _AddModeTile(
                    icon: Icons.event_note_outlined,
                    title: 'Файл / запись по расписанию',
                    subtitle: 'Выбрать занятие, дату и пару из расписания',
                    onTap: () => Navigator.pop(ctx, _AddEntryMode.lesson),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || mode == null) return;
    switch (mode) {
      case _AddEntryMode.diaryCalendar:
        await _openDiaryCalendar(data);
        break;
      case _AddEntryMode.personalTask:
        await _createPersonalTask(data);
        break;
      case _AddEntryMode.todaySubject:
        await _addBySubject(data, chooseDate: false);
        break;
      case _AddEntryMode.datedSubject:
        await _addBySubject(data, chooseDate: true);
        break;
      case _AddEntryMode.lesson:
        await _addByLesson();
        break;
    }
  }

  Future<void> _openDiaryCalendar(PersonalDiaryData data) async {
    final lessons = await _service.loadScheduleLessons();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return _DiaryCalendarSheet(
          data: data,
          lessons: lessons,
          assignmentDone: _assignmentDone,
          taskStatus: _taskStatus,
          onOpenSubject: (offeringId) {
            PersonalDiarySubject? subject;
            for (final item in data.subjects) {
              if (item.subjectOfferingId == offeringId) {
                subject = item;
                break;
              }
            }
            if (subject == null) return;
            Navigator.of(ctx).pop();
            _openSubjectDiary(subject);
          },
          onOpenAssignment: (assignment) {
            Navigator.of(ctx).pop();
            _openAssignmentDetails(assignment);
          },
          onOpenTask: (task) {
            Navigator.of(ctx).pop();
            _openPersonalTaskDetails(task);
          },
        );
      },
    );
  }

  Future<void> _createPersonalTask(PersonalDiaryData data) async {
    final task = await showModalBottomSheet<PersonalDiaryTask>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _PersonalTaskFormSheet(
        subjects: data.subjects,
        currentSemester: data.selectedSemesterNumber,
        onSave: ({
          required String title,
          String? description,
          PersonalDiarySubject? subject,
          DateTime? dueAt,
        }) async {
          return _service.createPersonalTask(
            title: title,
            description: description,
            subjectOfferingId: subject?.subjectOfferingId,
            subjectTitle: subject?.title,
            dueAt: dueAt,
          );
        },
      ),
    );
    if (task == null || !mounted) return;
    final updated = _dataWithCreatedTask(data, task);
    await _service.saveCached(updated);
    setState(() {
      _future = Future<PersonalDiaryData>.value(updated);
    });
    _refreshSilently();
  }

  Future<void> _addBySubject(
    PersonalDiaryData data, {
    required bool chooseDate,
  }) async {
    final selected = await _pickSubject(
      data.allSubjects,
      currentSemester: data.selectedSemesterNumber,
    );
    if (selected == null || !mounted) return;

    final now = DateTime.now();
    DateTime pickedDate = DateTime(now.year, now.month, now.day);
    if (chooseDate) {
      final selectedDate = await showDatePicker(
        context: context,
        initialDate: pickedDate,
        firstDate: DateTime(now.year - 5),
        lastDate: DateTime(now.year + 5),
        helpText: 'Дата записи',
        cancelText: 'Отмена',
        confirmText: 'Выбрать',
      );
      if (selectedDate == null || !mounted) return;
      pickedDate = selectedDate;
    }

    await _openQuickNote(
      subjectTitle: selected.title,
      args: selected.toDiaryArgs().copyWith(date: pickedDate),
      date: pickedDate,
    );
  }

  Future<void> _addByLesson() async {
    final lessons = await _service.loadScheduleLessons();
    if (!mounted) return;
    if (lessons.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Связанные занятия в расписании не найдены')),
      );
      return;
    }
    final selected = await _pickLesson(lessons);
    if (selected == null || !mounted) return;
    await _openQuickNote(
      subjectTitle: selected.subjectTitle,
      args: selected.toDiaryArgs(),
      date: selected.date,
    );
  }

  Future<PersonalDiarySubject?> _pickSubject(
    List<PersonalDiarySubject> subjects, {
    int? currentSemester,
  }) {
    return showModalBottomSheet<PersonalDiarySubject>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => _SubjectPickerSheet(
        subjects: subjects,
        currentSemester: currentSemester,
      ),
    );
  }

  Future<PersonalDiaryLesson?> _pickLesson(
    List<PersonalDiaryLesson> lessons,
  ) {
    return showModalBottomSheet<PersonalDiaryLesson>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => _LessonPickerSheet(lessons: lessons),
    );
  }

  Future<void> _openQuickNote({
    required String subjectTitle,
    required SubjectDiaryArgs args,
    required DateTime date,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SubjectQuickNoteScreen(
          subjectKey: subjectTitle,
          args: args,
          date: date,
        ),
      ),
    );
    if (mounted) _refresh();
  }
}

enum _AddEntryMode {
  diaryCalendar,
  personalTask,
  todaySubject,
  datedSubject,
  lesson
}

class _UpcomingDiaryItem {
  final PersonalDiaryAssignment? assignment;
  final PersonalDiaryTask? task;

  const _UpcomingDiaryItem.groupAssignment(this.assignment) : task = null;
  const _UpcomingDiaryItem.personalTask(this.task) : assignment = null;

  DateTime? get dueAt => assignment?.dueAt ?? task?.dueAt;
  DateTime get createdAt => assignment?.createdAt ?? task!.createdAt;
  String get title => assignment?.title ?? task!.title;
  String get subjectTitle => assignment?.subjectTitle ?? task!.subjectTitle;
  String? get description => assignment?.description ?? task?.description;
}

typedef _SavePersonalTask = Future<PersonalDiaryTask> Function({
  required String title,
  String? description,
  PersonalDiarySubject? subject,
  DateTime? dueAt,
});

class _DiaryCalendarSheet extends StatefulWidget {
  final PersonalDiaryData data;
  final List<PersonalDiaryLesson> lessons;
  final bool Function(PersonalDiaryAssignment assignment) assignmentDone;
  final String Function(PersonalDiaryTask task) taskStatus;
  final ValueChanged<String> onOpenSubject;
  final ValueChanged<PersonalDiaryAssignment> onOpenAssignment;
  final ValueChanged<PersonalDiaryTask> onOpenTask;

  const _DiaryCalendarSheet({
    required this.data,
    required this.lessons,
    required this.assignmentDone,
    required this.taskStatus,
    required this.onOpenSubject,
    required this.onOpenAssignment,
    required this.onOpenTask,
  });

  @override
  State<_DiaryCalendarSheet> createState() => _DiaryCalendarSheetState();
}

class _DiaryCalendarSheetState extends State<_DiaryCalendarSheet> {
  late DateTime _visibleMonth;
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final initial = _initialDayWithEvents();
    _visibleMonth = DateTime(initial.year, initial.month);
    _selectedDay = DateTime(initial.year, initial.month, initial.day);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * .88;
    final events = _eventsByDay();
    final selectedEvents = events[_dayKey(_selectedDay)] ?? const [];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Календарь дневника',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: Colors.black,
                            fontWeight: FontWeight.w900,
                          ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _visibleMonth =
                          DateTime(_visibleMonth.year, _visibleMonth.month - 1);
                    }),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _visibleMonth =
                          DateTime(_visibleMonth.year, _visibleMonth.month + 1);
                    }),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
              Text(
                '${_monthName(_visibleMonth.month)} ${_visibleMonth.year}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black54, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const _DiaryCalendarLegend(),
              const SizedBox(height: 10),
              _MonthGrid(
                month: _visibleMonth,
                selectedDay: _selectedDay,
                eventColorsForDay: (day) {
                  final dayEvents = events[_dayKey(day)] ?? const [];
                  return dayEvents.map(_eventColor).toList();
                },
                onSelect: (day) => setState(() => _selectedDay = day),
              ),
              const SizedBox(height: 10),
              Text(
                'События на ${_fmtDate(_selectedDay)}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: selectedEvents.isEmpty
                    ? const _EmptyCard(text: 'На этот день событий нет.')
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: selectedEvents.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (ctx, index) {
                          final event = selectedEvents[index];
                          return _DiaryCalendarEventTile(
                            event: event,
                            onTap: () => _openEvent(event),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, List<_DiaryCalendarEvent>> _eventsByDay() {
    final map = <String, List<_DiaryCalendarEvent>>{};
    void add(DateTime date, _DiaryCalendarEvent event) {
      (map[_dayKey(date)] ??= []).add(event);
    }

    for (final entry in widget.data.latestEntries) {
      add(
        entry.date,
        _DiaryCalendarEvent.entry(
          title: entry.subjectTitle,
          subtitle: entry.preview ?? 'Запись дневника',
          subjectOfferingId: entry.subjectOfferingId,
        ),
      );
    }
    for (final assignment in widget.data.publishedAssignments) {
      if (widget.assignmentDone(assignment)) continue;
      final due = assignment.dueAt;
      if (due == null) continue;
      add(
        due,
        _DiaryCalendarEvent.assignment(
          title: assignment.title,
          subtitle: 'Невыполненное задание группы',
          assignment: assignment,
        ),
      );
    }
    for (final task in widget.data.personalTasks) {
      final due = task.dueAt;
      if (due == null) continue;
      add(
        due,
        _DiaryCalendarEvent.task(
          title: task.title,
          subtitle:
              'Личная задача • ${_taskStatusLabel(widget.taskStatus(task))}',
          task: task,
        ),
      );
    }
    for (final lesson in widget.lessons) {
      add(
        lesson.date,
        _DiaryCalendarEvent.lesson(
          title: lesson.subjectTitle,
          subtitle: _lessonSubtitle(lesson),
          lesson: lesson,
        ),
      );
    }
    for (final events in map.values) {
      events.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return map;
  }

  DateTime _initialDayWithEvents() {
    final today = DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    final dates = <DateTime>[
      ...widget.lessons.map((lesson) => lesson.date),
      ...widget.data.publishedAssignments
          .where((assignment) => !widget.assignmentDone(assignment))
          .map((assignment) => assignment.dueAt)
          .whereType<DateTime>(),
      ...widget.data.personalTasks
          .map((task) => task.dueAt)
          .whereType<DateTime>(),
      ...widget.data.latestEntries.map((entry) => entry.date),
    ].map((date) => DateTime(date.year, date.month, date.day)).toList()
      ..sort((a, b) {
        final aDelta = a.difference(todayOnly).inDays.abs();
        final bDelta = b.difference(todayOnly).inDays.abs();
        return aDelta.compareTo(bDelta);
      });
    return dates.isEmpty ? todayOnly : dates.first;
  }

  String _lessonSubtitle(PersonalDiaryLesson lesson) {
    final parts = <String>[
      'Пара',
      if (lesson.pairNum != null) '${lesson.pairNum}-я',
      if ((lesson.timeStart ?? '').isNotEmpty) lesson.timeStart!,
    ];
    return parts.join(' • ');
  }

  void _openEvent(_DiaryCalendarEvent event) {
    switch (event.type) {
      case _DiaryCalendarEventType.entry:
        final offeringId = event.subjectOfferingId;
        if (offeringId != null) widget.onOpenSubject(offeringId);
        break;
      case _DiaryCalendarEventType.assignment:
        final assignment = event.assignment;
        if (assignment != null) widget.onOpenAssignment(assignment);
        break;
      case _DiaryCalendarEventType.task:
        final task = event.task;
        if (task != null) widget.onOpenTask(task);
        break;
      case _DiaryCalendarEventType.lesson:
        final lesson = event.lesson;
        if (lesson != null) widget.onOpenSubject(lesson.subjectOfferingId);
        break;
    }
  }

  Color _eventColor(_DiaryCalendarEvent event) {
    switch (event.type) {
      case _DiaryCalendarEventType.lesson:
        return const Color(0xFF7C63D8);
      case _DiaryCalendarEventType.assignment:
        return const Color(0xFFB58B3B);
      case _DiaryCalendarEventType.task:
        return const Color(0xFF8A72D8);
      case _DiaryCalendarEventType.entry:
        return const Color(0xFF2F9D84);
    }
  }

  String _dayKey(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String _monthName(int month) {
    const names = [
      'Январь',
      'Февраль',
      'Март',
      'Апрель',
      'Май',
      'Июнь',
      'Июль',
      'Август',
      'Сентябрь',
      'Октябрь',
      'Ноябрь',
      'Декабрь',
    ];
    return names[month - 1];
  }
}

enum _DiaryCalendarEventType { entry, assignment, task, lesson }

class _DiaryCalendarEvent {
  final _DiaryCalendarEventType type;
  final String title;
  final String subtitle;
  final String? subjectOfferingId;
  final PersonalDiaryAssignment? assignment;
  final PersonalDiaryTask? task;
  final PersonalDiaryLesson? lesson;

  const _DiaryCalendarEvent.entry({
    required this.title,
    required this.subtitle,
    required this.subjectOfferingId,
  })  : type = _DiaryCalendarEventType.entry,
        assignment = null,
        task = null,
        lesson = null;

  const _DiaryCalendarEvent.assignment({
    required this.title,
    required this.subtitle,
    required this.assignment,
  })  : type = _DiaryCalendarEventType.assignment,
        subjectOfferingId = null,
        task = null,
        lesson = null;

  const _DiaryCalendarEvent.task({
    required this.title,
    required this.subtitle,
    required this.task,
  })  : type = _DiaryCalendarEventType.task,
        subjectOfferingId = null,
        assignment = null,
        lesson = null;

  const _DiaryCalendarEvent.lesson({
    required this.title,
    required this.subtitle,
    required this.lesson,
  })  : type = _DiaryCalendarEventType.lesson,
        subjectOfferingId = null,
        assignment = null,
        task = null;

  IconData get icon {
    switch (type) {
      case _DiaryCalendarEventType.entry:
        return Icons.edit_note_rounded;
      case _DiaryCalendarEventType.assignment:
        return Icons.assignment_outlined;
      case _DiaryCalendarEventType.task:
        return Icons.task_alt_rounded;
      case _DiaryCalendarEventType.lesson:
        return Icons.school_outlined;
    }
  }
}

class _DiaryCalendarLegend extends StatelessWidget {
  const _DiaryCalendarLegend();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _CalendarLegendChip(color: Color(0xFF7C63D8), text: 'Пары'),
        _CalendarLegendChip(color: Color(0xFFB58B3B), text: 'Задания'),
        _CalendarLegendChip(color: Color(0xFF8A72D8), text: 'Личные'),
        _CalendarLegendChip(color: Color(0xFF2F9D84), text: 'Записи'),
      ],
    );
  }
}

class _CalendarLegendChip extends StatelessWidget {
  final Color color;
  final String text;

  const _CalendarLegendChip({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: Colors.black54, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final DateTime month;
  final DateTime selectedDay;
  final List<Color> Function(DateTime day) eventColorsForDay;
  final ValueChanged<DateTime> onSelect;

  const _MonthGrid({
    required this.month,
    required this.selectedDay,
    required this.eventColorsForDay,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    const weekdays = ['ПН', 'ВТ', 'СР', 'ЧТ', 'ПТ', 'СБ', 'ВС'];
    final first = DateTime(month.year, month.month, 1);
    final start = first.subtract(Duration(days: first.weekday - 1));
    final days = List.generate(42, (index) {
      return DateTime(start.year, start.month, start.day + index);
    });
    return Column(
      children: [
        Row(
          children: weekdays
              .map(
                (day) => Expanded(
                  child: Center(
                    child: Text(
                      day,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: Colors.black54),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: days.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemBuilder: (context, index) {
            final day = days[index];
            final isCurrentMonth = day.month == month.month;
            final selected = _sameDate(day, selectedDay);
            final colors = eventColorsForDay(day);
            return InkWell(
              onTap: () => onSelect(DateTime(day.year, day.month, day.day)),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF7C63D8) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.isNotEmpty
                        ? const Color(0xFF7C63D8)
                        : Colors.black.withValues(alpha: .06),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${day.day}',
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : isCurrentMonth
                                ? Colors.black87
                                : Colors.black26,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 3),
                    if (colors.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: colors.take(3).map((color) {
                          return Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: selected ? Colors.white : color,
                              shape: BoxShape.circle,
                            ),
                          );
                        }).toList(),
                      )
                    else
                      const SizedBox(height: 6),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DiaryCalendarEventTile extends StatelessWidget {
  final _DiaryCalendarEvent event;
  final VoidCallback onTap;

  const _DiaryCalendarEventTile({
    required this.event,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      tileColor: const Color(0xFFF6F7FB),
      leading: Icon(event.icon, color: const Color(0xFF7C63D8)),
      title: Text(
        event.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style:
            const TextStyle(color: Colors.black, fontWeight: FontWeight.w900),
      ),
      subtitle: Text(
        event.subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _PersonalTaskFormSheet extends StatefulWidget {
  final List<PersonalDiarySubject> subjects;
  final int? currentSemester;
  final _SavePersonalTask onSave;

  const _PersonalTaskFormSheet({
    required this.subjects,
    required this.currentSemester,
    required this.onSave,
  });

  @override
  State<_PersonalTaskFormSheet> createState() => _PersonalTaskFormSheetState();
}

class _PersonalTaskFormSheetState extends State<_PersonalTaskFormSheet> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  PersonalDiarySubject? _subject;
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
                  'Задача сохранится только в личном дневнике и не появится в чате.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.black54),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _titleController,
                  autofocus: true,
                  cursorColor: Colors.black87,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: _fieldDecoration('Название'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _descriptionController,
                  cursorColor: Colors.black87,
                  style: const TextStyle(color: Colors.black87),
                  minLines: 2,
                  maxLines: 4,
                  decoration: _fieldDecoration('Описание, если нужно'),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<PersonalDiarySubject?>(
                  initialValue: _subject,
                  decoration: _fieldDecoration('Предмет'),
                  isExpanded: true,
                  dropdownColor: Colors.white,
                  menuMaxHeight: maxHeight * .45,
                  iconEnabledColor: Colors.black87,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontWeight: FontWeight.w700,
                    overflow: TextOverflow.ellipsis,
                  ),
                  items: [
                    const DropdownMenuItem<PersonalDiarySubject?>(
                      value: null,
                      child: Text(
                        'Без предмета',
                        style: TextStyle(color: Colors.black87),
                      ),
                    ),
                    ...widget.subjects.map(
                      (subject) => DropdownMenuItem<PersonalDiarySubject?>(
                        value: subject,
                        child: Text(
                          subject.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.black87),
                        ),
                      ),
                    ),
                  ],
                  onChanged: (value) => setState(() => _subject = value),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _pickDueDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(_dueAt == null
                      ? 'Добавить дедлайн'
                      : 'Дедлайн: ${_fmtDate(_dueAt!)}'),
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

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.black54),
      floatingLabelStyle: const TextStyle(
        color: Colors.black87,
        fontWeight: FontWeight.w700,
      ),
      filled: true,
      fillColor: const Color(0xFFF6F7FB),
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
      final task = await widget.onSave(
        title: title,
        description: _descriptionController.text.trim(),
        subject: _subject,
        dueAt: _dueAt,
      );
      if (mounted) Navigator.pop(context, task);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось создать личную задачу')),
      );
    }
  }
}

enum _LessonFilter { upcoming, past, all }

class _SubjectPickerSheet extends StatefulWidget {
  final List<PersonalDiarySubject> subjects;
  final int? currentSemester;

  const _SubjectPickerSheet({
    required this.subjects,
    this.currentSemester,
  });

  @override
  State<_SubjectPickerSheet> createState() => _SubjectPickerSheetState();
}

class _SubjectPickerSheetState extends State<_SubjectPickerSheet> {
  final _searchController = TextEditingController();
  int? _semester;
  bool _showArchive = false;

  @override
  void initState() {
    super.initState();
    _semester = widget.currentSemester;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 390;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final query = _searchController.text.trim().toLowerCase();
    final semesters = widget.subjects
        .map((subject) => subject.semesterNumber)
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();
    final archiveSemesters = semesters
        .where((semester) => semester != widget.currentSemester)
        .toList();
    final filtered = widget.subjects.where((subject) {
      if (!_showArchive && widget.currentSemester != null) {
        if (subject.semesterNumber != widget.currentSemester) return false;
      }
      if (_showArchive && _semester != null) {
        if (subject.semesterNumber != _semester) return false;
      }
      if (_showArchive &&
          _semester == null &&
          widget.currentSemester != null &&
          subject.semesterNumber == widget.currentSemester) {
        return false;
      }
      if (query.isEmpty) return true;
      return subject.title.toLowerCase().contains(query);
    }).toList()
      ..sort(_compareSubjects);

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: compact ? .9 : .82,
        minChildSize: .5,
        maxChildSize: .94,
        builder: (context, scrollController) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 16,
              6,
              compact ? 12 : 16,
              12 + bottomInset,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PickerHeader(
                  title: 'Выбери предмет',
                  subtitle: 'Поиск, семестр и только нужные предметы.',
                ),
                const SizedBox(height: 10),
                _SearchField(
                  controller: _searchController,
                  hintText: 'Поиск по предмету',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterChipButton(
                        label: widget.currentSemester == null
                            ? 'Текущие'
                            : '${widget.currentSemester} семестр',
                        selected: !_showArchive,
                        onTap: () => setState(() {
                          _showArchive = false;
                          _semester = widget.currentSemester;
                        }),
                      ),
                      if (archiveSemesters.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _FilterChipButton(
                          label: 'Архив',
                          selected: _showArchive && _semester == null,
                          onTap: () => setState(() {
                            _showArchive = true;
                            _semester = null;
                          }),
                        ),
                      ],
                      if (_showArchive)
                        for (final semester in archiveSemesters) ...[
                          const SizedBox(width: 6),
                          _FilterChipButton(
                            label: '$semester семестр',
                            selected: _semester == semester,
                            onTap: () => setState(() => _semester = semester),
                          ),
                        ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _showArchive
                      ? 'Архив: ${filtered.length}'
                      : 'Основные предметы: ${filtered.length}',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: Colors.black54),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? const _PickerEmptyState(text: 'Ничего не найдено')
                      : ListView.separated(
                          controller: scrollController,
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 6),
                          itemBuilder: (ctx, index) {
                            final subject = filtered[index];
                            return _SubjectPickerTile(subject: subject);
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  int _compareSubjects(PersonalDiarySubject a, PersonalDiarySubject b) {
    final current = widget.currentSemester;
    if (current != null) {
      final aCurrent = a.semesterNumber == current;
      final bCurrent = b.semesterNumber == current;
      if (aCurrent != bCurrent) return aCurrent ? -1 : 1;
    }
    final semesterCompare =
        (b.semesterNumber ?? 0).compareTo(a.semesterNumber ?? 0);
    if (semesterCompare != 0) return semesterCompare;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }
}

class _LessonPickerSheet extends StatefulWidget {
  final List<PersonalDiaryLesson> lessons;

  const _LessonPickerSheet({required this.lessons});

  @override
  State<_LessonPickerSheet> createState() => _LessonPickerSheetState();
}

class _LessonPickerSheetState extends State<_LessonPickerSheet> {
  final _searchController = TextEditingController();
  _LessonFilter _filter = _LessonFilter.upcoming;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 390;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final query = _searchController.text.trim().toLowerCase();
    final filtered = widget.lessons.where((lesson) {
      final lessonDay =
          DateTime(lesson.date.year, lesson.date.month, lesson.date.day);
      switch (_filter) {
        case _LessonFilter.upcoming:
          if (lessonDay.isBefore(today)) return false;
          break;
        case _LessonFilter.past:
          if (!lessonDay.isBefore(today)) return false;
          break;
        case _LessonFilter.all:
          break;
      }
      if (query.isEmpty) return true;
      return lesson.subjectTitle.toLowerCase().contains(query);
    }).toList()
      ..sort((a, b) => _compareLessons(a, b, today));

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: compact ? .9 : .82,
        minChildSize: .5,
        maxChildSize: .94,
        builder: (context, scrollController) {
          return Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 16,
              6,
              compact ? 12 : 16,
              12 + bottomInset,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PickerHeader(
                  title: 'Выбери занятие',
                  subtitle: 'Поиск по расписанию с привязкой к паре.',
                ),
                const SizedBox(height: 10),
                _SearchField(
                  controller: _searchController,
                  hintText: 'Поиск по предмету',
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterChipButton(
                        label: 'Ближайшие',
                        selected: _filter == _LessonFilter.upcoming,
                        onTap: () =>
                            setState(() => _filter = _LessonFilter.upcoming),
                      ),
                      const SizedBox(width: 6),
                      _FilterChipButton(
                        label: 'Прошедшие',
                        selected: _filter == _LessonFilter.past,
                        onTap: () =>
                            setState(() => _filter = _LessonFilter.past),
                      ),
                      const SizedBox(width: 6),
                      _FilterChipButton(
                        label: 'Все',
                        selected: _filter == _LessonFilter.all,
                        onTap: () =>
                            setState(() => _filter = _LessonFilter.all),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Найдено: ${filtered.length}',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: Colors.black54),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? const _PickerEmptyState(text: 'Занятий не найдено')
                      : ListView.separated(
                          controller: scrollController,
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 6),
                          itemBuilder: (ctx, index) {
                            final lesson = filtered[index];
                            return _LessonPickerTile(lesson: lesson);
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  int _compareLessons(
    PersonalDiaryLesson a,
    PersonalDiaryLesson b,
    DateTime today,
  ) {
    switch (_filter) {
      case _LessonFilter.upcoming:
        final aDelta = a.date.difference(today).inDays;
        final bDelta = b.date.difference(today).inDays;
        final deltaCompare = aDelta.compareTo(bDelta);
        if (deltaCompare != 0) return deltaCompare;
        break;
      case _LessonFilter.past:
        final dateCompare = b.date.compareTo(a.date);
        if (dateCompare != 0) return dateCompare;
        break;
      case _LessonFilter.all:
        final distanceCompare = _distanceFromToday(a.date, today)
            .compareTo(_distanceFromToday(b.date, today));
        if (distanceCompare != 0) return distanceCompare;
        break;
    }
    final pairCompare = (a.pairNum ?? 0).compareTo(b.pairNum ?? 0);
    if (pairCompare != 0) return pairCompare;
    return a.subjectTitle.toLowerCase().compareTo(b.subjectTitle.toLowerCase());
  }

  int _distanceFromToday(DateTime date, DateTime today) {
    final day = DateTime(date.year, date.month, date.day);
    return day.difference(today).inDays.abs();
  }
}

class _PickerHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _PickerHeader({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 390;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: compact ? 20 : null,
                fontWeight: FontWeight.w900,
                color: Colors.black,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Colors.black54),
        ),
      ],
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  const _SearchField({
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
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      labelStyle: TextStyle(
        fontSize: 13,
        color: selected ? Colors.white : Colors.black87,
        fontWeight: FontWeight.w800,
      ),
      selectedColor: const Color(0xFF7C63D8),
      backgroundColor: Colors.white,
      side: BorderSide(
        color: selected
            ? const Color(0xFF7C63D8)
            : Colors.black.withValues(alpha: .08),
      ),
    );
  }
}

class _SubjectPickerTile extends StatelessWidget {
  final PersonalDiarySubject subject;

  const _SubjectPickerTile({required this.subject});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      tileColor: Colors.white,
      leading: _SubjectInitial(title: subject.title),
      title: Text(
        subject.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: subject.semesterNumber == null
          ? null
          : Text('${subject.semesterNumber} семестр'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.pop(context, subject),
    );
  }
}

class _LessonPickerTile extends StatelessWidget {
  final PersonalDiaryLesson lesson;

  const _LessonPickerTile({required this.lesson});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      tileColor: Colors.white,
      leading: _SubjectInitial(title: lesson.subjectTitle),
      title: Text(
        lesson.subjectTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(_lessonSubtitle(lesson)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.pop(context, lesson),
    );
  }

  String _lessonSubtitle(PersonalDiaryLesson lesson) {
    final parts = <String>[
      _fmtDate(lesson.date),
      if (lesson.pairNum != null) '${lesson.pairNum}-я пара',
      if ((lesson.timeStart ?? '').isNotEmpty) lesson.timeStart!,
      if (lesson.semesterNumber != null) '${lesson.semesterNumber} семестр',
    ];
    return parts.join(' • ');
  }
}

class _PickerEmptyState extends StatelessWidget {
  final String text;

  const _PickerEmptyState({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
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

class _AddModeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AddModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      tileColor: Colors.white,
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0xFF7C63D8).withValues(alpha: .10),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: const Color(0xFF7C63D8)),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _DiaryHeader extends StatelessWidget {
  final VoidCallback onAdd;

  const _DiaryHeader({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 390;
    return SizedBox(
      height: compact ? 88 : 96,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFFFFBFF), Color(0xFFF7FBFA)],
              ),
            ),
          ),
          Positioned(
            left: -34,
            top: -42,
            child: _SoftCircle(
              size: 128,
              color: const Color(0xFFEDE7F6).withValues(alpha: .72),
            ),
          ),
          Positioned(
            right: -48,
            bottom: -56,
            child: _SoftCircle(
              size: 160,
              color: Colors.white.withValues(alpha: .70),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 12 : 16,
                8,
                compact ? 12 : 16,
                8,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _HeaderRoundButton(
                      icon: Icons.arrow_back_ios_new_rounded,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 58),
                    child: Text(
                      'Мой дневник',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: Colors.black,
                        height: 1.0,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: .05),
                            offset: const Offset(0, 2),
                            blurRadius: 3,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _HeaderAddButton(
                      enabled: true,
                      onTap: onAdd,
                    ),
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

class _SoftCircle extends StatelessWidget {
  final double size;
  final Color color;

  const _SoftCircle({
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _HeaderRoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _HeaderRoundButton({
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: .86),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, size: 18, color: Colors.black87),
        ),
      ),
    );
  }
}

class _HeaderAddButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;

  const _HeaderAddButton({
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: enabled
                  ? const [Color(0xFF7C63D8), Color(0xFF8A72D8)]
                  : const [Color(0xFFE2E5F0), Color(0xFFC8CEDD)],
            ),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: const Color(0xFF7C63D8).withValues(alpha: .22),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: const Icon(Icons.add, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

class _DiarySummaryCard extends StatelessWidget {
  final PersonalDiaryData data;

  const _DiarySummaryCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEDE7F6), Color(0xFFD6F5EE)],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD9CCF5).withValues(alpha: .30),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.menu_book_rounded, color: Color(0xFF7C63D8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Текущий семестр',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF1F2937),
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ),
              if (data.selectedSemesterNumber != null)
                _WhitePill(text: '${data.selectedSemesterNumber} семестр'),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            data.selectedSemesterNumber == null
                ? 'Семестр не определён'
                : '${data.selectedSemesterNumber} семестр',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF1F2937).withValues(alpha: .74),
                  fontWeight: FontWeight.w700,
                ),
          ),
          if ((data.academicContext.recordBookNumber ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Зачётка № ${data.academicContext.recordBookNumber}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF1F2937).withValues(alpha: .74),
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Личные записи, задания и материалы по предметам семестра.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF1F2937).withValues(alpha: .66),
                  height: 1.3,
                ),
          ),
        ],
      ),
    );
  }
}

class _WhitePill extends StatelessWidget {
  final String text;

  const _WhitePill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF7C63D8).withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: const Color(0xFF7C63D8).withValues(alpha: .18)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF7C63D8),
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;

  const _SectionTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 390;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: compact ? 20 : null,
                fontWeight: FontWeight.w900,
                color: Colors.black,
              ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
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
    );
  }
}

class _CollapsibleTasksSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<_UpcomingDiaryItem> items;
  final Widget Function(_UpcomingDiaryItem item) itemBuilder;

  const _CollapsibleTasksSection({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.items,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      decoration: _cardDecoration(),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          leading: Icon(
            icon,
            color: const Color(0xFF7C63D8),
          ),
          title: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                ),
          ),
          subtitle: Text(
            subtitle,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.black54),
          ),
          children: items.map(itemBuilder).toList(),
        ),
      ),
    );
  }
}

class _CollapsibleSubjectsSection extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final List<PersonalDiarySubject> subjects;
  final ValueChanged<PersonalDiarySubject> onTap;

  const _CollapsibleSubjectsSection({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.subjects,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      decoration: _cardDecoration(),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          leading: Icon(icon, color: const Color(0xFF7C63D8)),
          title: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.black87,
                ),
          ),
          subtitle: Text(
            subtitle,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.black54),
          ),
          children: subjects.isEmpty
              ? [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: _EmptyCard(text: 'Пока пусто.'),
                  ),
                ]
              : subjects
                  .map(
                    (subject) => _SubjectCard(
                      subject: subject,
                      onTap: () => onTap(subject),
                    ),
                  )
                  .toList(),
        ),
      ),
    );
  }
}

class _AssignmentDiaryCard extends StatelessWidget {
  final PersonalDiaryAssignment assignment;
  final bool done;
  final VoidCallback onTap;
  final VoidCallback onToggleDone;

  const _AssignmentDiaryCard({
    required this.assignment,
    required this.done,
    required this.onTap,
    required this.onToggleDone,
  });

  @override
  Widget build(BuildContext context) {
    final dueText = _assignmentDueText(assignment);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _cardDecoration(),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: done
                          ? const Color(0xFF2F9D84).withValues(alpha: .12)
                          : const Color(0xFF7C63D8).withValues(alpha: .10),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      done
                          ? Icons.check_circle_rounded
                          : Icons.assignment_outlined,
                      color: done
                          ? const Color(0xFF2F9D84)
                          : const Color(0xFF7C63D8),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          assignment.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    color: Colors.black,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${assignment.subjectTitle}${dueText == null ? '' : ' • $dueText'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.black54,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _StatusBadge(done: done),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: onToggleDone,
                    icon: Icon(
                      done
                          ? Icons.undo_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 18,
                    ),
                    label: Text(done ? 'Снять' : 'Выполнить'),
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

class _StatusBadge extends StatelessWidget {
  final bool done;

  const _StatusBadge({required this.done});

  @override
  Widget build(BuildContext context) {
    final color = done ? const Color(0xFF2F9D84) : const Color(0xFFB58B3B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        done ? 'Выполнено' : 'Не выполнено',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _PersonalTaskCard extends StatelessWidget {
  final PersonalDiaryTask task;
  final String statusOverride;
  final VoidCallback onTap;
  final VoidCallback onChangeStatus;

  const _PersonalTaskCard({
    required this.task,
    required this.statusOverride,
    required this.onTap,
    required this.onChangeStatus,
  });

  @override
  Widget build(BuildContext context) {
    final dueText = _dateLabel(task.dueAt);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: _cardDecoration(),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C63D8).withValues(alpha: .10),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.task_alt_rounded,
                      color: Color(0xFF7C63D8),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          task.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w900,
                                    color: Colors.black,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${task.subjectTitle}${dueText == null ? '' : ' • $dueText'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.black54,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const _KindBadge(text: 'Личная задача'),
                  const SizedBox(width: 8),
                  _TaskStatusBadge(task: task, statusOverride: statusOverride),
                  const Spacer(),
                  TextButton(
                    onPressed: onChangeStatus,
                    child: const Text('Статус'),
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

class _KindBadge extends StatelessWidget {
  final String text;

  const _KindBadge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF7C63D8).withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF7C63D8),
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _TaskStatusBadge extends StatelessWidget {
  final PersonalDiaryTask task;
  final String? statusOverride;

  const _TaskStatusBadge({required this.task, this.statusOverride});

  @override
  Widget build(BuildContext context) {
    final status = statusOverride ?? task.status;
    final color = switch (status) {
      'done' => const Color(0xFF2F9D84),
      'in_progress' => const Color(0xFF7C63D8),
      _ => const Color(0xFFB58B3B),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _taskStatusLabel(status),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _PersonalTaskDetailsSheet extends StatelessWidget {
  final PersonalDiaryTask task;
  final String statusOverride;
  final Future<void> Function(String status) onSetStatus;

  const _PersonalTaskDetailsSheet({
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                const _KindBadge(text: 'Личная задача'),
                _TaskStatusBadge(task: task, statusOverride: statusOverride),
                if (_dateLabel(task.dueAt) != null)
                  _InfoChip(text: _dateLabel(task.dueAt)!),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              task.subjectTitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black54,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 14),
            Text(
              (task.description ?? '').trim().isEmpty
                  ? 'Описания нет.'
                  : task.description!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black87,
                    height: 1.35,
                  ),
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

class _AssignmentDetailsSheet extends StatelessWidget {
  final PersonalDiaryAssignment assignment;
  final bool done;
  final Future<void> Function() onToggleDone;

  const _AssignmentDetailsSheet({
    required this.assignment,
    required this.done,
    required this.onToggleDone,
  });

  @override
  Widget build(BuildContext context) {
    final dueText = _assignmentDueText(assignment);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    assignment.title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Colors.black,
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                ),
                const SizedBox(width: 10),
                _StatusBadge(done: done),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              assignment.subjectTitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black54,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            if (dueText != null) ...[
              const SizedBox(height: 4),
              Text(
                dueText,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF7C63D8),
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              assignment.description.trim().isEmpty
                  ? 'Описания нет.'
                  : assignment.description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.black87,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async => onToggleDone(),
                icon: Icon(
                  done
                      ? Icons.undo_rounded
                      : Icons.check_circle_outline_rounded,
                ),
                label: Text(
                  done ? 'Отметить как не выполнено' : 'Отметить как выполнено',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubjectCard extends StatelessWidget {
  final PersonalDiarySubject subject;
  final VoidCallback onTap;

  const _SubjectCard({required this.subject, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: _cardDecoration(),
          child: Row(
            children: [
              _SubjectInitial(title: subject.title),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subject.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _subjectMeta(subject),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.black54,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    if ((subject.latestPreview ?? '').isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        subject.latestPreview!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: Colors.black87),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.black38),
            ],
          ),
        ),
      ),
    );
  }

  String _subjectMeta(PersonalDiarySubject subject) {
    final parts = <String>[
      'Записей: ${subject.entryCount}',
      'Файлов: ${subject.fileCount}',
    ];
    if (subject.assignmentCount > 0) {
      final pending = subject.incompleteAssignmentCount;
      parts.add(pending > 0
          ? 'Заданий группы: ${subject.assignmentCount} ($pending осталось)'
          : 'Заданий группы: ${subject.assignmentCount}');
    }
    if (subject.personalTaskCount > 0) {
      final active = subject.activePersonalTaskCount;
      parts.add(active > 0
          ? 'Личных задач: ${subject.personalTaskCount} ($active активных)'
          : 'Личных задач: ${subject.personalTaskCount}');
    }
    if (subject.latestEntryDate != null) {
      parts.add('Последняя: ${_fmtDate(subject.latestEntryDate!)}');
    }
    return parts.join(' • ');
  }
}

class _LatestEntryCard extends StatelessWidget {
  final PersonalDiaryLatestEntry entry;

  const _LatestEntryCard(this.entry);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.subjectTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.black,
                ),
          ),
          const SizedBox(height: 6),
          Text(
            '${_fmtDate(entry.date)} • Файлов: ${entry.fileCount}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.black54),
          ),
          if ((entry.preview ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              entry.preview!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.black87),
            ),
          ],
        ],
      ),
    );
  }
}

class _SubjectInitial extends StatelessWidget {
  final String title;

  const _SubjectInitial({required this.title});

  @override
  Widget build(BuildContext context) {
    final letter = title.trim().isEmpty ? 'П' : title.trim()[0].toUpperCase();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF7C63D8).withValues(alpha: .10),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: const Color(0xFF7C63D8),
            ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String text;

  const _EmptyCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
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

class _InfoChip extends StatelessWidget {
  final String text;

  const _InfoChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF7C63D8).withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF7C63D8),
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}

BoxDecoration _cardDecoration() {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(18),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: .06),
        blurRadius: 16,
        offset: const Offset(0, 6),
      ),
    ],
  );
}

String _fmtDate(DateTime date) {
  return '${date.day.toString().padLeft(2, '0')}.'
      '${date.month.toString().padLeft(2, '0')}.'
      '${date.year}';
}

String? _dateLabel(DateTime? date) {
  if (date == null) return null;
  return 'до ${_fmtDate(date)}';
}

String _taskStatusLabel(String status) {
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

String? _assignmentDueText(PersonalDiaryAssignment assignment) {
  if (assignment.dueAt != null) {
    return 'до ${_fmtDate(assignment.dueAt!)}';
  }
  final due = (assignment.dueText ?? '').trim();
  return due.isEmpty ? null : 'до $due';
}
