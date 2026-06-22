// lib/src/ui/schedule/schedule_screen.dart
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/lesson.dart';
import 'lesson_details_screen.dart';
import 'widgets/lesson_card.dart';
import 'widgets/mini_calendar.dart';
import 'widgets/calendar_icon_button.dart';

class ScheduleRepository {
  final _sb = Supabase.instance.client;

  /// Грузим все занятия за календарный месяц [anchor] (1-е число → последнее).
  Future<List<Lesson>> loadMonth(DateTime anchor) async {
    try {
      final first = DateTime(anchor.year, anchor.month, 1);
      final last =
          DateTime(anchor.year, anchor.month + 1, 0); // последний день месяца
      final days = last.difference(first).inDays + 1;

      final resp = await _sb.rpc('get_my_lessons', params: {
        'p_from':
            DateTime(first.year, first.month, first.day).toIso8601String(),
        'p_days': days,
      }).timeout(const Duration(seconds: 14));

      if (resp is List) {
        final list = resp
            .map((m) => Lesson.fromMap(Map<String, dynamic>.from(m as Map)))
            .toList();
        final enriched = await _enrichAcademicLinks(list);
        // ignore: avoid_print
        print(
            '[schedule] loaded ${enriched.length} lessons for ${anchor.year}-${anchor.month}');
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
          .inFilter('id', ids)
          .timeout(const Duration(seconds: 7));

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
}

const double _kHeaderExpandedHeight = 128.0; // как в «Командах»
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
  List<Lesson> _all = [];
  RealtimeChannel? _channel;

  // свайп-трекинг
  double _dragDx = 0.0;

  // Цвета типов (для мини-календаря и легенды)
  static const Color _cLecture = Color(0xFFE53935);
  static const Color _cPractice = Color(0xFF1E88E5);
  static const Color _cLab = Color(0xFF8E24AA);

  @override
  void initState() {
    super.initState();
    final now = _nowMsk();
    _selectedDay = now;
    _selectedWeekStart = _mondayOf(now);
    _loadMonth(anchor: _selectedDay);

    // Realtime (если включено на сервере)
    _channel = Supabase.instance.client
        .channel('public:lessons')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'lessons',
          callback: (_) => _loadMonth(anchor: _selectedDay),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  // ===== helpers

  DateTime _nowMsk() {
    final nowUtc = DateTime.now().toUtc();
    return nowUtc.add(const Duration(hours: 3)); // Москва UTC+3
  }

  DateTime _mondayOf(DateTime d) {
    final wd = d.weekday; // 1..7
    return DateTime(d.year, d.month, d.day).subtract(Duration(days: wd - 1));
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _loadMonth({required DateTime anchor}) async {
    setState(() => _loading = true);
    final data = await _repo.loadMonth(anchor);
    if (!mounted) return;
    setState(() {
      _all = data;
      _loading = false;
    });
    // ВАЖНО: не меняем _selectedDay и не «подскакиваем» к другой дате.
  }

  void _shiftWeek(int deltaWeeks) {
    final nextStart = _selectedWeekStart.add(Duration(days: 7 * deltaWeeks));
    final nextDay = nextStart; // выбрали понедельник той недели
    setState(() {
      _selectedWeekStart = nextStart;
      _selectedDay = nextDay;
    });
    _loadMonth(anchor: _selectedDay); // если месяц поменялся — подтянем данные
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

  List<DateTime> get _weekDays =>
      List.generate(7, (i) => _selectedWeekStart.add(Duration(days: i)));

  List<Lesson> get _forSelectedDay {
    return _all.where((l) => _isSameDate(l.date, _selectedDay)).toList()
      ..sort((a, b) {
        final t = a.pairNum.compareTo(b.pairNum);
        if (t != 0) return t;
        final aMin = a.start.hour * 60 + a.start.minute;
        final bMin = b.start.hour * 60 + b.start.minute;
        return aMin.compareTo(bMin);
      });
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
    return set.toList();
  }

  Future<void> _pickDateFromHeader() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay,
      firstDate: DateTime(DateTime.now().year - 1),
      lastDate: DateTime(DateTime.now().year + 2),
    );
    if (picked != null) {
      setState(() {
        _selectedDay = picked;
        _selectedWeekStart = _mondayOf(picked);
      });
      _loadMonth(anchor: _selectedDay);
    }
  }

  void _onMenuSelected(String key) {
    switch (key) {
      case 'today':
        final now = _nowMsk();
        setState(() {
          _selectedDay = now;
          _selectedWeekStart = _mondayOf(now);
        });
        _loadMonth(anchor: _selectedDay);
        break;
      case 'this_week':
        final now = _nowMsk();
        setState(() {
          _selectedWeekStart = _mondayOf(now);
          _selectedDay = _selectedWeekStart;
        });
        _loadMonth(anchor: _selectedDay);
        break;
      case 'sort_time':
        setState(() {});
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final monthText = _monthName(_selectedDay.month);
    final yearText = _selectedDay.year.toString();

    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _dragDx = 0,
        onHorizontalDragUpdate: (d) => _dragDx += d.delta.dx,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          // быстрый флик по скорости
          if (v.abs() > 250) {
            if (v < 0) {
              _shiftDay(1); // влево → следующий день
            } else {
              _shiftDay(-1); // вправо → предыдущий день
            }
            return;
          }
          // медленный свайп по смещению
          if (_dragDx < -40) {
            _shiftDay(1);
          } else if (_dragDx > 40) {
            _shiftDay(-1);
          }
          _dragDx = 0.0;
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ===== фиксированная шапка (как в «Командах») =====
            SizedBox(
              height: _kHeaderExpandedHeight,
              child: _ScheduleHeader(
                title: 'Расписание',
                subtitle: '$monthText $yearText',

                // ↓↓↓ иконка-календарь + меню
                day: _selectedDay,
                eventColors: _colorsForDay,
                legendItems: {
                  _cLecture: 'Лекция',
                  _cPractice: 'Практика',
                  _cLab: 'Лабораторная',
                },
                onDatePicked: (picked) {
                  setState(() {
                    _selectedDay = picked;
                    _selectedWeekStart = _mondayOf(picked);
                  });
                  _loadMonth(anchor: _selectedDay);
                },
                onEnsureMonthLoaded: (monthStart) =>
                    _loadMonth(anchor: monthStart),

                menuBuilder: (ctx) => PopupMenuButton<String>(
                  onSelected: _onMenuSelected,
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(value: 'today', child: Text('Сегодня')),
                    PopupMenuItem(
                        value: 'this_week', child: Text('Текущая неделя')),
                    PopupMenuItem(
                        value: 'sort_time',
                        child: Text('Сортировка: по времени')),
                  ],
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
            ),
            const SizedBox(height: _kHeaderSpacing),

            // ===== мини-календарь (фикс) =====
            MiniCalendar(
              weekDays: _weekDays,
              selectedDay: _selectedDay,
              eventColors: _colorsForDay,
              onPrevWeek: () => _shiftWeek(-1),
              onNextWeek: () => _shiftWeek(1),
              onSelect: (d) {
                setState(() {
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
            }),

            const Divider(height: 1),

            // ===== лента — единственная прокручиваемая часть =====
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _forSelectedDay.isEmpty
                      ? const _EmptyCat()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                          itemCount: _forSelectedDay.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, i) {
                            final l = _forSelectedDay[i];
                            return LessonCard(
                              lesson: l,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        LessonDetailsScreen(lesson: l)),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
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
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.white,
                theme.colorScheme.primary.withOpacity(0.06),
                theme.colorScheme.primary.withOpacity(0.12),
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
                    color: theme.colorScheme.primary.withOpacity(0.10))),
            Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                    diameter: 160, color: Colors.white.withOpacity(0.55))),
          ]),
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
                  CalendarIconButton(
                    day: day,
                    eventColors: eventColors,
                    legendItems: legendItems,
                    onPicked: onDatePicked,
                    onEnsureMonthLoaded:
                        onEnsureMonthLoaded ?? (DateTime _) async {},
                  ),
                  const SizedBox(width: 14),
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
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                            height: 1.05,
                            shadows: [
                              Shadow(
                                  color: Colors.black.withOpacity(0.05),
                                  offset: const Offset(0, 2),
                                  blurRadius: 3)
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Colors.black.withOpacity(0.64),
                                    height: 1.25,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  menuBuilder != null
                      ? menuBuilder!(context)
                      : PopupMenuButton<String>(
                          onSelected: (_) {},
                          itemBuilder: (ctx) => const [
                            PopupMenuItem(
                                value: 'today', child: Text('Сегодня')),
                            PopupMenuItem(
                                value: 'this_week',
                                child: Text('Текущая неделя')),
                            PopupMenuItem(
                                value: 'sort_time',
                                child: Text('Сортировка: по времени')),
                          ],
                          icon: const Icon(Icons.more_horiz),
                        ),
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
  const _EmptyCat();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Lottie.asset('assets/lottie/cat_sleeping.json',
            width: 180, height: 180, repeat: true),
        const SizedBox(height: 12),
        const Text('Здесь пока пусто',
            style: TextStyle(fontSize: 14, color: Colors.grey)),
      ]),
    );
  }
}
