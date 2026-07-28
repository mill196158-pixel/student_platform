// lib/src/ui/schedule/schedule_screen.dart
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lottie/lottie.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../learning/assignment_details_screen.dart';
import '../learning/models/team.dart';
import '../learning/state/team_cubit.dart';
import '../learning/tabs/chat/data/chat_group_actions_repository.dart';
import '../learning/tabs/chat/navigation/group_action_deeplink.dart';
import 'models/lesson.dart';
import 'models/schedule_group_action_event.dart';
import 'models/schedule_group_action_mapper.dart';
import 'lesson_details_screen.dart';
import 'widgets/lesson_card.dart';
import 'widgets/mini_calendar.dart';
import 'widgets/calendar_icon_button.dart';
import 'utils/msk_date.dart';

class ScheduleRepository {
  final _sb = Supabase.instance.client;

  /// Грузим все занятия за календарный месяц [anchor] (1-е число → последнее).
  Future<List<Lesson>> loadMonth(DateTime anchor) async {
    final first = DateTime(anchor.year, anchor.month, 1);
    final last =
        DateTime(anchor.year, anchor.month + 1, 0); // последний день месяца
    final days = last.difference(first).inDays + 1;
    return loadRange(first, days: days);
  }

  Future<List<Lesson>> loadRange(DateTime from, {required int days}) async {
    try {
      final start = MskDate.calendarDate(from);

      final resp = await _sb.rpc('get_my_lessons', params: {
        'p_from': MskDate.isoDate(start),
        'p_days': days,
      });

      if (resp is List) {
        final list = resp
            .map((m) => Lesson.fromMap(Map<String, dynamic>.from(m as Map)))
            .toList();
        final enriched = await _enrichAcademicLinks(list);
        // ignore: avoid_print
        print(
            '[schedule] loaded ${enriched.length} lessons from ${MskDate.isoDate(start)} for $days days');
        return enriched;
      }
      return [];
    } catch (e, st) {
      // ignore: avoid_print
      print('RPC get_my_lessons error: $e\n$st');
      return [];
    }
  }

  Future<List<Lesson>> _enrichAcademicLinks(List<Lesson> lessons) async {
    final ids = lessons
        .map((lesson) => lesson.id)
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return lessons;

    try {
      final rows = await _sb
          .from('lessons')
          .select(
            'id,group_id,subject_id,subject_offering_id,academic_year_id,academic_term_id,semester_number,alias_match_status',
          )
          .inFilter('id', ids);

      final byId = <String, Map<String, dynamic>>{};
      for (final raw in rows) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['id'] ?? '').toString();
        if (id.isNotEmpty) byId[id] = row;
      }

      return lessons
          .map((lesson) => lesson.copyWithAcademicFields(byId[lesson.id]))
          .toList();
    } catch (e, st) {
      // ignore: avoid_print
      print('Schedule enrichment error: $e\n$st');
      return lessons;
    }
  }

  Future<List<ScheduleAssignment>> loadMonthAssignments(DateTime anchor) async {
    try {
      final first = DateTime(anchor.year, anchor.month, 1);
      final nextMonth = DateTime(anchor.year, anchor.month + 1, 1);
      const select =
          'id,team_id,title,body,description,due_at,due_text,status,published_at,subject_offering_id,created_at';
      final datedRows = await _sb
          .from('assignments')
          .select(select)
          .not('due_at', 'is', null)
          .gte('due_at', first.toIso8601String())
          .lt('due_at', nextMonth.toIso8601String())
          .or('status.eq.published,published_at.not.is.null')
          .order('due_at', ascending: true);

      final textRows = await _sb
          .from('assignments')
          .select(select)
          .filter('due_at', 'is', null)
          .not('due_text', 'is', null)
          .or('status.eq.published,published_at.not.is.null')
          .order('created_at', ascending: false);

      final rawById = <String, Map<String, dynamic>>{};
      for (final raw in [...datedRows as List, ...textRows as List]) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = (row['id'] ?? '').toString();
        if (id.isNotEmpty) rawById[id] = row;
      }

      final rawAssignments = rawById.values.where((row) {
        final dueAt = ScheduleAssignment.parseDueAt(
          row,
          fallbackYear: anchor.year,
        );
        return dueAt != null &&
            !dueAt.isBefore(first) &&
            dueAt.isBefore(nextMonth);
      }).toList();
      if (rawAssignments.isEmpty) return const [];

      final offeringIds = rawAssignments
          .map((row) => (row['subject_offering_id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final offeringTitles = <String, String>{};
      if (offeringIds.isNotEmpty) {
        try {
          final offeringRows = await _sb
              .from('subject_offerings')
              .select('id,display_name')
              .inFilter('id', offeringIds);
          for (final raw in offeringRows as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = (row['id'] ?? '').toString();
            final title = (row['display_name'] ?? '').toString().trim();
            if (id.isNotEmpty && title.isNotEmpty) offeringTitles[id] = title;
          }
        } catch (_) {}
      }

      final ids = rawAssignments
          .map((row) => (row['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      final teamIds = rawAssignments
          .map((row) => (row['team_id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();
      final teamsById = <String, Map<String, dynamic>>{};
      if (teamIds.isNotEmpty) {
        try {
          final teamRows = await _sb
              .from('teams')
              .select(
                'id,name,teacher,icon,group_name,group_id,subject_id,subject_offering_id,academic_year_id,academic_term_id,semester_number',
              )
              .inFilter('id', teamIds);
          for (final raw in teamRows as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = (row['id'] ?? '').toString();
            if (id.isNotEmpty) teamsById[id] = row;
          }
        } catch (_) {}
      }
      final doneById = <String, bool>{};
      if (ids.isNotEmpty) {
        try {
          final doneRows = await _sb
              .from('assignment_done')
              .select('assignment_id,done')
              .inFilter('assignment_id', ids);
          for (final raw in doneRows as List) {
            final row = Map<String, dynamic>.from(raw as Map);
            final id = (row['assignment_id'] ?? '').toString();
            if (id.isNotEmpty) doneById[id] = (row['done'] ?? false) == true;
          }
        } catch (_) {}
      }

      return rawAssignments
          .map((row) => ScheduleAssignment.fromRow(
                row,
                fallbackYear: anchor.year,
                subjectTitleByOfferingId: offeringTitles,
                teamsById: teamsById,
                completed: doneById[(row['id'] ?? '').toString()] == true,
              ))
          .where((assignment) => assignment.dueAt != null)
          .toList();
    } catch (e, st) {
      // ignore: avoid_print
      print('Schedule assignments load error: $e\n$st');
      return const [];
    }
  }

  Future<List<ScheduleGroupActionEvent>> loadMonthGroupActions(
    DateTime anchor,
  ) async {
    try {
      final first = DateTime(anchor.year, anchor.month, 1);
      final last = DateTime(anchor.year, anchor.month + 1, 0, 23, 59, 59);
      final repo = ChatGroupActionsRepository(client: _sb);
      final raw = await repo.listMyGroupActionDeadlinesCached(
        from: first,
        to: last,
      );
      return mapScheduleGroupActionEvents(raw);
    } catch (e, st) {
      // ignore: avoid_print
      print('Schedule group actions load error: $e\n$st');
      final repo = ChatGroupActionsRepository(client: _sb);
      final first = DateTime(anchor.year, anchor.month, 1);
      final last = DateTime(anchor.year, anchor.month + 1, 0, 23, 59, 59);
      return mapScheduleGroupActionEvents(
        await repo.peekCachedDeadlines(from: first, to: last),
      );
    }
  }
}

class ScheduleAssignment {
  final String id;
  final String title;
  final String description;
  final DateTime? dueAt;
  final String? dueText;
  final String? subjectTitle;
  final Team team;
  final bool completed;

  const ScheduleAssignment({
    required this.id,
    required this.title,
    required this.description,
    required this.dueAt,
    required this.team,
    this.dueText,
    this.subjectTitle,
    this.completed = false,
  });

  factory ScheduleAssignment.fromRow(
    Map<String, dynamic> row, {
    required int fallbackYear,
    required Map<String, String> subjectTitleByOfferingId,
    required Map<String, Map<String, dynamic>> teamsById,
    required bool completed,
  }) {
    final offeringId = (row['subject_offering_id'] ?? '').toString();
    final teamId = (row['team_id'] ?? '').toString();
    final teamRow = teamsById[teamId];
    final description = (row['description'] ?? '').toString().trim();
    final body = (row['body'] ?? '').toString().trim();
    final subjectTitle = _nullIfEmpty(subjectTitleByOfferingId[offeringId]);

    return ScheduleAssignment(
      id: (row['id'] ?? '').toString(),
      title: (row['title'] ?? 'Задание').toString().trim(),
      description: description.isNotEmpty ? description : body,
      dueAt: parseDueAt(row, fallbackYear: fallbackYear),
      dueText: _nullIfEmpty(row['due_text']),
      subjectTitle: subjectTitle,
      team: _teamFromRow(
        teamId: teamId,
        teamRow: teamRow,
        fallbackTitle: subjectTitle ?? 'Команда',
        fallbackOfferingId: _nullIfEmpty(offeringId),
      ),
      completed: completed,
    );
  }

  static Team _teamFromRow({
    required String teamId,
    required Map<String, dynamic>? teamRow,
    required String fallbackTitle,
    required String? fallbackOfferingId,
  }) {
    String value(String key) => (teamRow?[key] ?? '').toString().trim();
    String? nullable(String key) => _nullIfEmpty(teamRow?[key]);

    return Team(
      id: teamId,
      name: value('name').isNotEmpty ? value('name') : fallbackTitle,
      teacher: value('teacher'),
      groupCode: value('group_name'),
      icon: value('icon').isNotEmpty ? value('icon') : '📚',
      subjectOfferingId: nullable('subject_offering_id') ?? fallbackOfferingId,
      groupId: nullable('group_id'),
      subjectId: nullable('subject_id'),
      academicYearId: nullable('academic_year_id'),
      academicTermId: nullable('academic_term_id'),
      semesterNumber: _nullableInt(teamRow?['semester_number']),
    );
  }

  static DateTime? parseDueAt(
    Map<String, dynamic> row, {
    required int fallbackYear,
  }) {
    final dueAt = DateTime.tryParse((row['due_at'] ?? '').toString());
    if (dueAt != null) return dueAt;

    final text = (row['due_text'] ?? '').toString().trim();
    if (text.isEmpty) return null;

    final match =
        RegExp(r'(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?').firstMatch(text);
    if (match == null) return null;

    final day = int.tryParse(match.group(1) ?? '');
    final month = int.tryParse(match.group(2) ?? '');
    final rawYear = int.tryParse(match.group(3) ?? '');
    if (day == null || month == null) return null;

    final year = rawYear == null
        ? fallbackYear
        : rawYear < 100
            ? 2000 + rawYear
            : rawYear;
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return parsed;
  }

  static String? _nullIfEmpty(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  static int? _nullableInt(dynamic value) {
    if (value is int) return value;
    return int.tryParse((value ?? '').toString());
  }
}

const double _kHeaderSpacing = 12.0;

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});
  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  final _repo = ScheduleRepository();

  late DateTime _selectedWeekStart;
  late DateTime _selectedDay;
  bool _loading = true;
  bool _weekMode = false; // режим «День»/«Неделя»
  List<Lesson> _all = [];
  List<ScheduleAssignment> _assignments = [];
  List<ScheduleGroupActionEvent> _groupActions = [];
  RealtimeChannel? _channel;
  RealtimeChannel? _assignmentsChannel;

  // недельный режим: прокрутка + якорь на «сегодня»
  final ScrollController _weekScrollController = ScrollController();
  final GlobalKey _todaySectionKey = GlobalKey();
  // свёрнутые дни в недельной ленте (ключ — ISO-дата дня)
  final Set<String> _collapsedDays = {};
  // «тик» раз в минуту — чтобы индикатор «идёт сейчас/следующая» был живым
  Timer? _liveTick;

  // свайп-трекинг
  double _dragDx = 0.0;

  // Цвета типов (для мини-календаря и легенды)
  static const Color _cLecture = Color(0xFFE53935);
  static const Color _cPractice = Color(0xFF1E88E5);
  static const Color _cLab = Color(0xFF8E24AA);
  static const Color _cAssignment = Color(0xFFF59E0B);

  @override
  void initState() {
    super.initState();
    final now = _nowMsk();
    _selectedDay = now;
    _selectedWeekStart = _mondayOf(now);
    _loadMonth(anchor: _selectedDay);

    // Обновляем «живые» индикаторы пар раз в минуту.
    _liveTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });

    // Realtime (если включено на сервере)
    _channel = Supabase.instance.client
        .channel('public:lessons')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'lessons',
          callback: (_) => _reload(),
        )
        .subscribe();
    _assignmentsChannel = Supabase.instance.client
        .channel('public:assignments:schedule')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'assignments',
          callback: (_) => _reload(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _assignmentsChannel?.unsubscribe();
    _liveTick?.cancel();
    _weekScrollController.dispose();
    super.dispose();
  }

  // ===== helpers

  DateTime _nowMsk() => MskDate.now();

  DateTime _mondayOf(DateTime d) {
    final wd = d.weekday; // 1..7
    return DateTime(d.year, d.month, d.day).subtract(Duration(days: wd - 1));
  }

  bool _isSameDate(DateTime a, DateTime b) => MskDate.isSameCalendarDate(a, b);

  /// Единая точка перезагрузки данных под текущий режим.
  Future<void> _reload() {
    return _weekMode ? _loadWeek() : _loadMonth(anchor: _selectedDay);
  }

  Future<void> _loadMonth({required DateTime anchor}) async {
    setState(() => _loading = true);
    final data = await Future.wait<dynamic>([
      _repo.loadMonth(anchor),
      _repo.loadMonthAssignments(anchor),
      _repo.loadMonthGroupActions(anchor),
    ]);
    if (!mounted) return;
    setState(() {
      _all = data[0] as List<Lesson>;
      _assignments = data[1] as List<ScheduleAssignment>;
      _groupActions = data[2] as List<ScheduleGroupActionEvent>;
      _loading = false;
    });
    // ВАЖНО: не меняем _selectedDay и не «подскакиваем» к другой дате.
  }

  /// Грузим данные для всей видимой недели. Неделя может пересекать границу
  /// месяца — тогда подтягиваем оба месяца и объединяем по id.
  Future<void> _loadWeek() async {
    setState(() => _loading = true);
    final weekStart = _selectedWeekStart;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final anchors = <DateTime>{
      DateTime(weekStart.year, weekStart.month, 1),
      DateTime(weekEnd.year, weekEnd.month, 1),
    };

    final lessonsById = <String, Lesson>{};
    final assignmentsById = <String, ScheduleAssignment>{};
    final groupActionsByKey = <String, ScheduleGroupActionEvent>{};
    for (final anchor in anchors) {
      final data = await Future.wait<dynamic>([
        _repo.loadMonth(anchor),
        _repo.loadMonthAssignments(anchor),
        _repo.loadMonthGroupActions(anchor),
      ]);
      for (final l in data[0] as List<Lesson>) {
        lessonsById[l.id] = l;
      }
      for (final a in data[1] as List<ScheduleAssignment>) {
        assignmentsById[a.id] = a;
      }
      for (final action in data[2] as List<ScheduleGroupActionEvent>) {
        groupActionsByKey[action.dedupeKey] = action;
      }
    }

    if (!mounted) return;
    setState(() {
      _all = lessonsById.values.toList();
      _assignments = assignmentsById.values.toList();
      _groupActions = groupActionsByKey.values.toList()
        ..sort((a, b) => a.occursAt.compareTo(b.occursAt));
      _loading = false;
    });
  }

  void _shiftWeek(int deltaWeeks) {
    final nextStart = _selectedWeekStart.add(Duration(days: 7 * deltaWeeks));
    setState(() {
      _selectedWeekStart = nextStart;
      // В режиме дня выбираем понедельник новой недели, чтобы лента дня
      // соответствовала календарю. В режиме недели «выбранный день» не виден.
      _selectedDay = nextStart;
    });
    _reload(); // если месяц/неделя поменялись — подтянем данные
  }

  void _shiftDay(int deltaDays) {
    final next = DateTime(
        _selectedDay.year, _selectedDay.month, _selectedDay.day + deltaDays);
    setState(() {
      _selectedDay = next;
      _selectedWeekStart = _mondayOf(next);
    });
    _loadMonth(anchor: next);
  }

  /// Переключение режима «День» ⇄ «Неделя».
  void _setWeekMode(bool week) {
    if (_weekMode == week) return;
    setState(() {
      _weekMode = week;
      if (week) {
        _selectedWeekStart = _mondayOf(_selectedDay);
      }
    });
    _reload();
    if (week) _scrollToTodaySoon();
  }

  /// Плавно подкручиваем ленту недели к секции «сегодня» (если она в неделе).
  void _scrollToTodaySoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _todaySectionKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.02,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  List<DateTime> get _weekDays =>
      List.generate(7, (i) => _selectedWeekStart.add(Duration(days: i)));

  List<Lesson> _lessonsForDay(DateTime day) {
    return _all.where((l) => _isSameDate(l.date, day)).toList()
      ..sort((a, b) {
        final t = a.pairNum.compareTo(b.pairNum);
        if (t != 0) return t;
        final aMin = a.start.hour * 60 + a.start.minute;
        final bMin = b.start.hour * 60 + b.start.minute;
        return aMin.compareTo(bMin);
      });
  }

  List<ScheduleAssignment> _assignmentsForDay(DateTime day) {
    return _assignments
        .where((assignment) =>
            assignment.dueAt != null && _isSameDate(assignment.dueAt!, day))
        .toList()
      ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
  }

  List<Lesson> get _forSelectedDay => _lessonsForDay(_selectedDay);

  List<ScheduleGroupActionEvent> _groupActionsForDay(DateTime day) {
    return _groupActions
        .where((action) => _isSameDate(action.occursAt, day))
        .toList()
      ..sort((a, b) => a.occursAt.compareTo(b.occursAt));
  }

  /// Ordinary assignments + topic/collection deadlines in one deadline-sorted list.
  List<_ScheduleDueEntry> _dueEntriesForDay(DateTime day) {
    final entries = <_ScheduleDueEntry>[
      for (final a in _assignmentsForDay(day)) _ScheduleDueEntry.assignment(a),
      for (final g in _groupActionsForDay(day)) _ScheduleDueEntry.groupAction(g),
    ]..sort((a, b) => a.occursAt.compareTo(b.occursAt));
    return entries;
  }

  /// Живые статусы пар для дня: все идущие сейчас + одна ближайшая следующая.
  /// Пусто, если [day] — не сегодня. [dayLessons] должен быть отсортирован.
  Map<String, LessonLiveStatus> _liveStatusFor(
    List<Lesson> dayLessons,
    DateTime day,
    DateTime now,
  ) {
    final result = <String, LessonLiveStatus>{};
    if (!_isSameDate(day, now)) return result;
    final nowMin = now.hour * 60 + now.minute;

    for (final l in dayLessons) {
      final s = l.start.hour * 60 + l.start.minute;
      final e = l.end.hour * 60 + l.end.minute;
      if (nowMin >= s && nowMin < e) {
        result[l.id] = LessonLiveStatus.ongoing;
      }
    }
    for (final l in dayLessons) {
      final s = l.start.hour * 60 + l.start.minute;
      if (s > nowMin) {
        result.putIfAbsent(l.id, () => LessonLiveStatus.next);
        break;
      }
    }
    return result;
  }

  List<Color> _colorsForDay(DateTime d) {
    final lessons = _all.where((l) => _isSameDate(l.date, d));
    final set = <Color>{};
    for (final l in lessons) {
      switch (l.type) {
        case LessonType.lecture:
          set.add(_cLecture);
          break;
        case LessonType.practice:
          set.add(_cPractice);
          break;
        case LessonType.lab:
          set.add(_cLab);
          break;
        case LessonType.other:
          break;
      }
    }
    final hasDue = _assignments.any(
          (assignment) =>
              assignment.dueAt != null && _isSameDate(assignment.dueAt!, d),
        ) ||
        _groupActions.any((action) => _isSameDate(action.occursAt, d));
    if (hasDue) {
      set.add(_cAssignment);
    }
    return set.toList();
  }

  void _onMenuSelected(String key) {
    switch (key) {
      case 'today':
        // «Сегодня» уважает текущий режим: в неделе → текущая неделя,
        // в дне → сегодняшний день. И там и там подскроллим к сегодня.
        final now = _nowMsk();
        setState(() {
          _selectedDay = now;
          _selectedWeekStart = _mondayOf(now);
        });
        _reload();
        if (_weekMode) _scrollToTodaySoon();
        break;
      case 'view_day':
        _setWeekMode(false);
        break;
      case 'view_week':
        _setWeekMode(true);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = '${_monthName(_selectedDay.month)} ${_selectedDay.year}';

    void handleSwipe(int dir) => _weekMode ? _shiftWeek(dir) : _shiftDay(dir);
    final headerHeight =
        (MediaQuery.paddingOf(context).top + 86.0).clamp(128.0, 150.0);

    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _dragDx = 0,
        onHorizontalDragUpdate: (d) => _dragDx += d.delta.dx,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          // быстрый флик по скорости
          if (v.abs() > 250) {
            handleSwipe(v < 0 ? 1 : -1); // влево → вперёд, вправо → назад
            return;
          }
          // медленный свайп по смещению
          if (_dragDx < -40) {
            handleSwipe(1);
          } else if (_dragDx > 40) {
            handleSwipe(-1);
          }
          _dragDx = 0.0;
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ===== фиксированная шапка (как в «Командах») =====
            SizedBox(
              height: headerHeight,
              child: _ScheduleHeader(
                title: 'Расписание',
                subtitle: subtitle,

                // ↓↓↓ иконка-календарь + меню
                day: _selectedDay,
                eventColors: _colorsForDay,
                legendItems: {
                  _cLecture: 'Лекция',
                  _cPractice: 'Практика',
                  _cLab: 'Лабораторная',
                  _cAssignment: 'Задание',
                },
                onDatePicked: (picked) {
                  setState(() {
                    _weekMode = false;
                    _selectedDay = picked;
                    _selectedWeekStart = _mondayOf(picked);
                  });
                  _loadMonth(anchor: _selectedDay);
                },
                onEnsureMonthLoaded: (monthStart) =>
                    _loadMonth(anchor: monthStart),

                menuBuilder: (ctx) => _ScheduleHeaderMenu(
                  onSelected: _onMenuSelected,
                  weekMode: _weekMode,
                ),
              ),
            ),
            const SizedBox(height: _kHeaderSpacing),

            // ===== мини-календарь / полоса недели (фикс) =====
            MiniCalendar(
              weekDays: _weekDays,
              selectedDay: _selectedDay,
              weekMode: _weekMode,
              weekLabel: _weekRangeShort(),
              weekYearLabel: _weekYearLabel(),
              eventColors: _colorsForDay,
              onPrevWeek: () => _shiftWeek(-1),
              onNextWeek: () => _shiftWeek(1),
              onSelect: (d) {
                // Тап по дню — всегда переход в подробный режим дня.
                setState(() {
                  _weekMode = false;
                  _selectedDay = d;
                  _selectedWeekStart = _mondayOf(d);
                });
                _loadMonth(anchor: d);
              },
            ),

            // ===== легенда типов (фикс) =====
            CalendarLegend(items: {
              _cLecture: 'Лекция',
              _cPractice: 'Практика',
              _cLab: 'Лабораторная',
              _cAssignment: 'Задание',
            }),

            const Divider(height: 1),

            // ===== лента — единственная прокручиваемая часть =====
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return _weekMode ? _buildWeekBody(context) : _buildDayBody(context);
  }

  Widget _buildDayBody(BuildContext context) {
    final lessons = _forSelectedDay;
    final dueEntries = _dueEntriesForDay(_selectedDay);
    if (lessons.isEmpty && dueEntries.isEmpty) {
      return const _EmptyCat();
    }
    final live = _liveStatusFor(lessons, _selectedDay, _nowMsk());
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        for (final l in lessons) ...[
          LessonCard(
            lesson: l,
            status: live[l.id] ?? LessonLiveStatus.none,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LessonDetailsScreen(lesson: l),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (dueEntries.isNotEmpty) ...[
          const _ScheduleSectionLabel(title: 'Задания к дате'),
          const SizedBox(height: 10),
          for (final entry in dueEntries) ...[
            _buildDueEntryCard(entry),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }

  Widget _buildDueEntryCard(_ScheduleDueEntry entry) {
    final assignment = entry.assignment;
    if (assignment != null) {
      return ScheduleAssignmentCard(
        assignment: assignment,
        onTap: () => _openAssignmentDetails(assignment),
      );
    }
    final action = entry.groupAction!;
    return ScheduleGroupActionCard(
      event: action,
      onTap: () => _openGroupAction(action),
      onDelete: action.canDelete ? () => _deleteGroupAction(action) : null,
    );
  }

  Widget _buildWeekBody(BuildContext context) {
    final today = _nowMsk();
    final days = _weekDays;

    // Показываем только дни с парами/заданиями — пустые дни не рисуем.
    final contentDays = days
        .where((d) =>
            _lessonsForDay(d).isNotEmpty ||
            _assignmentsForDay(d).isNotEmpty ||
            _groupActionsForDay(d).isNotEmpty)
        .toList();

    // Вся неделя пустая — показываем понятную заглушку.
    if (contentDays.isEmpty) {
      return const _EmptyCat(message: 'На этой неделе занятий нет');
    }

    return ListView(
      controller: _weekScrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        for (final d in contentDays)
          _buildWeekDaySection(context, d, isToday: _isSameDate(d, today)),
      ],
    );
  }

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  void _toggleDayCollapsed(DateTime day) {
    final key = _dayKey(day);
    setState(() {
      if (!_collapsedDays.remove(key)) _collapsedDays.add(key);
    });
  }

  Widget _buildWeekDaySection(
    BuildContext context,
    DateTime day, {
    required bool isToday,
  }) {
    final lessons = _lessonsForDay(day);
    final dueEntries = _dueEntriesForDay(day);

    final collapsed = _collapsedDays.contains(_dayKey(day));
    final live = _liveStatusFor(lessons, day, _nowMsk());

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        for (final l in lessons) ...[
          LessonCard(
            lesson: l,
            status: live[l.id] ?? LessonLiveStatus.none,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LessonDetailsScreen(lesson: l),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (dueEntries.isNotEmpty) ...[
          const _ScheduleSectionLabel(title: 'Задания к дате'),
          const SizedBox(height: 10),
          for (final entry in dueEntries) ...[
            _buildDueEntryCard(entry),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );

    return Padding(
      key: isToday ? _todaySectionKey : null,
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WeekDayHeader(
            date: day,
            weekdayName: _weekdayFull(day.weekday),
            dateLabel: '${day.day} ${_monthGenitive(day.month)}',
            lessonCount: lessons.length,
            assignmentCount: dueEntries.length,
            isToday: isToday,
            collapsed: collapsed,
            onTap: () => _toggleDayCollapsed(day),
          ),
          // Плавное сворачивание содержимого дня.
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: collapsed ? 0.0 : 1.0,
                child: content,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _monthName(int m) {
    const ru = [
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
      'Декабрь'
    ];
    return ru[m - 1];
  }

  static const _monthsGenitive = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];

  static const _weekdaysFull = [
    'Понедельник',
    'Вторник',
    'Среда',
    'Четверг',
    'Пятница',
    'Суббота',
    'Воскресенье',
  ];

  String _monthGenitive(int m) => _monthsGenitive[m - 1];

  String _weekdayFull(int weekday) => _weekdaysFull[weekday - 1];

  /// Короткий диапазон недели для мини-календаря (без года): «22–28 июня»
  /// или «29 июня – 5 июля» при переходе через месяц.
  String _weekRangeShort() {
    final s = _selectedWeekStart;
    final e = s.add(const Duration(days: 6));
    if (s.month == e.month) {
      return '${s.day}–${e.day} ${_monthGenitive(s.month)}';
    }
    return '${s.day} ${_monthGenitive(s.month)} – '
        '${e.day} ${_monthGenitive(e.month)}';
  }

  /// Год недели для мини-календаря (приглушённо рядом с диапазоном).
  String _weekYearLabel() {
    final s = _selectedWeekStart;
    final e = s.add(const Duration(days: 6));
    return s.year == e.year ? '${s.year}' : '${s.year}/${e.year}';
  }

  void _openAssignmentDetails(ScheduleAssignment assignment) {
    if (assignment.team.id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть команду задания')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ScheduleAssignmentDetailsRoute(
          assignment: assignment,
        ),
      ),
    );
  }

  Future<void> _deleteGroupAction(ScheduleGroupActionEvent event) async {
    if (!event.canDelete) return;
    final kind = event.isTopic ? 'topic_selection' : 'group_collection';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(event.isTopic ? 'Удалить список тем?' : 'Удалить сбор?'),
        content: const Text('Действие будет отменено для всех участников.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ChatGroupActionsRepository().deleteGroupAction(
        kind: kind,
        entityId: event.entityId,
      );
      if (!mounted) return;
      setState(() {
        _groupActions =
            _groupActions.where((e) => e.entityId != event.entityId).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(event.isTopic ? 'Список тем удалён' : 'Сбор удалён'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Не удалось удалить. Возможно, уже есть отметки участников.',
          ),
        ),
      );
    }
  }

  void _openGroupAction(ScheduleGroupActionEvent event) {
    openGroupActionDeeplink(
      context,
      GroupActionDeeplinkArgs.fromDeadline(
        eventType: event.eventType,
        entityId: event.entityId,
        chatId: event.chatId,
        cardMessageId: event.cardMessageId,
        teamId: event.teamId,
      ),
    );
  }
}

class _ScheduleAssignmentDetailsRoute extends StatefulWidget {
  final ScheduleAssignment assignment;

  const _ScheduleAssignmentDetailsRoute({required this.assignment});

  @override
  State<_ScheduleAssignmentDetailsRoute> createState() =>
      _ScheduleAssignmentDetailsRouteState();
}

class _ScheduleAssignmentDetailsRouteState
    extends State<_ScheduleAssignmentDetailsRoute> {
  late final TeamCubit _cubit;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _cubit = TeamCubit(widget.assignment.team);
    _initFuture = _cubit.init();
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              backgroundColor: Color(0xFFFAF8FC),
              body: Center(child: CircularProgressIndicator()),
            );
          }

          if (snapshot.hasError) {
            return const _AssignmentOpenErrorScreen(
              text: 'Не удалось загрузить задание',
            );
          }

          return BlocBuilder<TeamCubit, TeamState>(
            builder: (context, state) {
              final exists = state.assignments.any(
                (item) => item.id == widget.assignment.id,
              );
              if (!exists) {
                return const _AssignmentOpenErrorScreen(
                  text: 'Задание не найдено в этой команде',
                );
              }

              return AssignmentDetailsScreen(
                assignmentId: widget.assignment.id,
              );
            },
          );
        },
      ),
    );
  }
}

class _AssignmentOpenErrorScreen extends StatelessWidget {
  final String text;

  const _AssignmentOpenErrorScreen({required this.text});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAF8FC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Задание'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.black54,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ),
    );
  }
}

class _ScheduleSectionLabel extends StatelessWidget {
  final String title;

  const _ScheduleSectionLabel({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, left: 2),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Colors.black.withValues(alpha: 0.62),
              fontWeight: FontWeight.w900,
              letterSpacing: 0.1,
            ),
      ),
    );
  }
}

/// Заголовок дня в недельной ленте: дата-плашка, день недели, счётчик пар.
class _WeekDayHeader extends StatelessWidget {
  final DateTime date;
  final String weekdayName;
  final String dateLabel;
  final int lessonCount;
  final int assignmentCount;
  final bool isToday;
  final bool collapsed;
  final VoidCallback onTap;

  const _WeekDayHeader({
    required this.date,
    required this.weekdayName,
    required this.dateLabel,
    required this.lessonCount,
    required this.assignmentCount,
    required this.isToday,
    required this.collapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final accent = isToday ? primary : Colors.black.withValues(alpha: 0.82);

    final countText = lessonCount == 0
        ? (assignmentCount > 0 ? 'Только задания' : 'Нет пар')
        : '$lessonCount ${_ruPlural(lessonCount, 'пара', 'пары', 'пар')}';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isToday ? primary.withValues(alpha: 0.06) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: isToday
              ? Border.all(color: primary.withValues(alpha: 0.14))
              : null,
        ),
        child: Row(
          children: [
            // Дата-плашка
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isToday ? primary : theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isToday ? primary : primary.withValues(alpha: 0.16),
                ),
                boxShadow: isToday
                    ? [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.28),
                          blurRadius: 12,
                          offset: const Offset(0, 5),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                '${date.day}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: isToday ? Colors.white : Colors.black,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          weekdayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: accent,
                            height: 1.05,
                          ),
                        ),
                      ),
                      if (isToday) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: primary,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Сегодня',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '$dateLabel · $countText',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            // Индикатор сворачивания — анимированный шеврон в мягком круге.
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: AnimatedRotation(
                turns: collapsed ? -0.25 : 0.0,
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeInOutCubic,
                child: Icon(
                  Icons.expand_more_rounded,
                  size: 22,
                  color: primary.withValues(alpha: 0.9),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Русское склонение числительных.
String _ruPlural(int n, String one, String few, String many) {
  final mod10 = n % 10;
  final mod100 = n % 100;
  if (mod10 == 1 && mod100 != 11) return one;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return few;
  return many;
}

class ScheduleAssignmentCard extends StatelessWidget {
  final ScheduleAssignment assignment;
  final VoidCallback onTap;

  const ScheduleAssignmentCard({
    super.key,
    required this.assignment,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const color = _ScheduleScreenState._cAssignment;
    final due = assignment.dueAt;
    final dueText =
        assignment.dueText ?? (due == null ? 'К дате' : _fmtDue(due));
    final description = assignment.description.trim();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
          border: Border(
            left: BorderSide(color: color.withValues(alpha: 0.9), width: 4),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 86,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dueText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: color,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'дедлайн',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          assignment.title.isEmpty
                              ? 'Задание'
                              : assignment.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                            height: 1.08,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _AssignmentBadge(
                        completed: assignment.completed,
                        color: color,
                      ),
                    ],
                  ),
                  if ((assignment.subjectTitle ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.menu_book_outlined, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            assignment.subjectTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.black.withValues(alpha: 0.70),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.assignment_outlined, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.black.withValues(alpha: 0.70),
                            ),
                          ),
                        ),
                      ],
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

  static String _fmtDue(DateTime due) {
    final hasTime = due.hour != 0 || due.minute != 0;
    final date = '${due.day.toString().padLeft(2, '0')}.'
        '${due.month.toString().padLeft(2, '0')}';
    if (!hasTime) return date;
    return '$date ${due.hour.toString().padLeft(2, '0')}:'
        '${due.minute.toString().padLeft(2, '0')}';
  }
}

/// Same card basis as [ScheduleAssignmentCard]; thematic icon is the only kind cue.
class ScheduleGroupActionCard extends StatelessWidget {
  final ScheduleGroupActionEvent event;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const ScheduleGroupActionCard({
    super.key,
    required this.event,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const color = _ScheduleScreenState._cAssignment;
    final dueText = ScheduleAssignmentCard._fmtDue(event.occursAt);
    final teamLabel = (event.teamName ?? '').trim();
    final pick = (event.myPickText ?? '').trim();
    final title = event.title.trim().isEmpty ? 'Задание' : event.title.trim();
    final kindIcon = event.isTopic
        ? Icons.format_list_numbered_rtl
        : Icons.volunteer_activism_outlined;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 14,
              offset: const Offset(0, 3),
            ),
          ],
          border: Border(
            left: BorderSide(color: color.withValues(alpha: 0.9), width: 4),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 86,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    dueText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: color,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'дедлайн',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: Icon(kindIcon, size: 18, color: color),
                      ),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                            height: 1.08,
                          ),
                        ),
                      ),
                      if (onDelete != null)
                        PopupMenuButton<String>(
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            Icons.more_vert_rounded,
                            size: 20,
                            color: Colors.black.withValues(alpha: 0.55),
                          ),
                          onSelected: (v) {
                            if (v == 'delete') onDelete!();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Удалить'),
                            ),
                          ],
                        )
                      else
                        const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.26),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            )
                          ],
                        ),
                        child: Text(
                          event.statusLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (teamLabel.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Icon(Icons.groups_outlined, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            teamLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.black.withValues(alpha: 0.70),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (pick.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.check_circle_outline, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            pick,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.black.withValues(alpha: 0.70),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
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
}

/// Unified row for "Задания к дате" (ordinary assignment or group action).
class _ScheduleDueEntry {
  const _ScheduleDueEntry._({this.assignment, this.groupAction});

  factory _ScheduleDueEntry.assignment(ScheduleAssignment a) =>
      _ScheduleDueEntry._(assignment: a);

  factory _ScheduleDueEntry.groupAction(ScheduleGroupActionEvent g) =>
      _ScheduleDueEntry._(groupAction: g);

  final ScheduleAssignment? assignment;
  final ScheduleGroupActionEvent? groupAction;

  DateTime get occursAt =>
      assignment?.dueAt ??
      groupAction?.occursAt ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

class _AssignmentBadge extends StatelessWidget {
  final bool completed;
  final Color color;

  const _AssignmentBadge({required this.completed, required this.color});

  @override
  Widget build(BuildContext context) {
    final badgeColor = completed ? const Color(0xFF10B981) : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: badgeColor,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: badgeColor.withValues(alpha: 0.26),
            blurRadius: 8,
            offset: const Offset(0, 3),
          )
        ],
      ),
      child: Text(
        completed ? 'Готово' : 'Задание',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Шапка — как в «Командах», с иконкой-календарём (тап → выбор даты) и троеточием.
class _ScheduleHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  // НОВОЕ:
  final DateTime day;
  final List<Color> Function(DateTime) eventColors;
  final Map<Color, String>? legendItems;
  final ValueChanged<DateTime> onDatePicked;

  final Future<void> Function(DateTime)? onEnsureMonthLoaded;

  final WidgetBuilder? menuBuilder;

  const _ScheduleHeader({
    required this.title,
    required this.subtitle,
    required this.day,
    required this.eventColors,
    required this.onDatePicked,
    this.legendItems,
    this.onEnsureMonthLoaded,
    this.menuBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = MediaQuery.sizeOf(context).height < 760;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white,
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.colorScheme.primary.withValues(alpha: 0.12),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(children: [
            Positioned(
                left: -40,
                top: -20,
                child: _GlowCircle(
                    diameter: 140,
                    color: theme.colorScheme.primary.withValues(alpha: 0.10))),
            Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                    diameter: 160,
                    color: Colors.white.withValues(alpha: 0.55))),
          ]),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, compact ? 4 : 8, 16, 6),
            child: Align(
              alignment: Alignment(-1, compact ? 0.08 : 0.18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CalendarIconButton(
                    day: day,
                    eventColors: eventColors,
                    legendItems: legendItems,
                    onPicked: onDatePicked,
                    onEnsureMonthLoaded:
                        onEnsureMonthLoaded ?? (DateTime _) async {},
                  ),
                  SizedBox(width: compact ? 12 : 14),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                            fontSize: compact ? 30 : null,
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                            height: 1.05,
                            shadows: [
                              Shadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  offset: const Offset(0, 2),
                                  blurRadius: 3)
                            ],
                          ),
                        ),
                        SizedBox(height: compact ? 2 : 4),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: (compact
                                  ? Theme.of(context).textTheme.bodySmall
                                  : Theme.of(context).textTheme.bodyMedium)
                              ?.copyWith(
                            color: Colors.black.withValues(alpha: 0.64),
                            height: 1.12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  menuBuilder != null
                      ? menuBuilder!(context)
                      : _ScheduleHeaderMenu(
                          onSelected: (_) {}, weekMode: false),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScheduleHeaderMenu extends StatelessWidget {
  final ValueChanged<String> onSelected;
  final bool weekMode;

  const _ScheduleHeaderMenu({
    required this.onSelected,
    required this.weekMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return PopupMenuButton<String>(
      tooltip: 'Действия с расписанием',
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 10),
      elevation: 18,
      color: Colors.white,
      surfaceTintColor: Colors.white,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: primary.withValues(alpha: 0.08)),
      ),
      constraints: const BoxConstraints(minWidth: 244),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'today',
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: weekMode
              ? const _ScheduleMenuItem(
                  icon: Icons.date_range_rounded,
                  title: 'Текущая неделя',
                  subtitle: 'Вернуться к этой неделе',
                )
              : const _ScheduleMenuItem(
                  icon: Icons.today_rounded,
                  title: 'Сегодня',
                  subtitle: 'Вернуться к текущему дню',
                ),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem(
          value: 'view_day',
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _ScheduleMenuItem(
            icon: Icons.calendar_view_day_rounded,
            title: 'По дням',
            subtitle: 'Подробно, один день',
            active: !weekMode,
          ),
        ),
        PopupMenuItem(
          value: 'view_week',
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _ScheduleMenuItem(
            icon: Icons.calendar_view_week_rounded,
            title: 'По неделям',
            subtitle: 'Обзор всей недели',
            active: weekMode,
          ),
        ),
      ],
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: primary.withValues(alpha: 0.10)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Icon(Icons.more_horiz_rounded, color: primary, size: 26),
      ),
    );
  }
}

class _ScheduleMenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;

  const _ScheduleMenuItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: primary.withValues(alpha: active ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: active ? primary : const Color(0xFF111827),
                  fontWeight: FontWeight.w800,
                  height: 1.05,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF6B7280),
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
        if (active) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_circle_rounded, color: primary, size: 20),
        ],
      ],
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double diameter;
  final Color color;
  const _GlowCircle({required this.diameter, required this.color});
  @override
  Widget build(BuildContext context) => ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        ),
      );
}

/// Пустое состояние — котик
class _EmptyCat extends StatelessWidget {
  final String message;
  const _EmptyCat({this.message = 'Здесь пока пусто'});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Lottie.asset('assets/lottie/cat_sleeping.json',
            width: 180, height: 180, repeat: true),
        const SizedBox(height: 12),
        Text(message, style: const TextStyle(fontSize: 14, color: Colors.grey)),
      ]),
    );
  }
}
