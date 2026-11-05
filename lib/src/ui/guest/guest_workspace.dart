import 'guest_presentation_theme.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'guest_surface.dart';
import 'guest_account_screen.dart';
import 'guest_public_service.dart';
import '../home/home_dashboard_service.dart' show mapPublishedNews;
import '../shared/student_section_headers.dart';
import '../info/info_screen.dart' show GuestInfoScreen;
import '../profile/profile_screen.dart' show MapSpbgasuScreen;
import '../navigation/main_tab_scope.dart';
import '../schedule/widgets/mini_calendar.dart';

class GuestWorkspace extends StatefulWidget {
  const GuestWorkspace({super.key, required this.tab, this.service});
  final int tab;
  final GuestPublicService? service;
  @override
  State<GuestWorkspace> createState() => _GuestWorkspaceState();
}

class _GuestWorkspaceState extends State<GuestWorkspace> {
  late final GuestPublicService _service =
      widget.service ?? GuestPublicService();
  bool _ready = false, _weekMode = false, _accountScreenOpen = false;
  bool _newsFailed = false, _lessonsLoading = false;
  bool _groupPickerOpen = false;
  String? _lessonsError;
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  Map<String, dynamic>? _group;
  List<Map<String, dynamic>> _news = [], _lessons = [];
  final Map<String, Uint8List> _images = {};
  int _lessonRequest = 0;
  int _newsRequest = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_loadNews());
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('guest_selected_group_v1');
      if (raw != null) {
        final row = jsonDecode(raw);
        if (row is Map && row['id'] is String && row['name'] is String)
          _group = Map<String, dynamic>.from(row);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _ready = true);
    unawaited(_loadLessons());
  }

  Future<void> _loadNews() async {
    final generation = ++_newsRequest;
    try {
      final rows = await _service.rpc('get_guest_news');
      if (!mounted || generation != _newsRequest) return;
      setState(() {
        final oldRows = {for (final row in _news) row['id']: row};
        final retained = <String, Uint8List>{};
        for (final row in rows) {
          final id = row['id'];
          if (id is! String || id.isEmpty) continue;
          final old = oldRows[id];
          final previous = old == null ? null : guestNewsImageKey(old);
          final next = guestNewsImageKey(row);
          final bytes = _images[id];
          if (bytes != null && previous != null && previous.id == next?.id) {
            retained[id] = bytes;
          }
        }
        _news = rows;
        _images
          ..clear()
          ..addAll(retained);
        _newsFailed = false;
      });
      var next = 0;
      Future<void> worker() async {
        while (next < rows.length && mounted && generation == _newsRequest) {
          final row = rows[next++];
          try {
            Uint8List? bytes;
            for (var attempt = 0; attempt < 2; attempt++) {
              try {
                bytes = await _service.image(row);
              } catch (_) {}
              if (bytes != null || !mounted || generation != _newsRequest)
                break;
              if (attempt == 0)
                await Future<void>.delayed(const Duration(milliseconds: 300));
            }
            if (mounted && generation == _newsRequest && bytes != null) {
              final loaded = bytes;
              setState(() => _images[row['id'] as String] = loaded);
            }
          } catch (_) {}
        }
      }

      await Future.wait(
          List.generate(rows.length.clamp(0, 6), (_) => worker()));
    } catch (_) {
      if (mounted && generation == _newsRequest)
        setState(() => _newsFailed = true);
    }
  }

  DateTime get _monday => _day.subtract(Duration(days: _day.weekday - 1));
  String _date(DateTime d) => d.toIso8601String().substring(0, 10);
  void _selectDay(DateTime d) {
    setState(() => _day = DateUtils.dateOnly(d));
    unawaited(_loadLessons());
  }

  List<Color> _eventColors(DateTime d) =>
      _lessons.any((l) => l['date'] == _date(d)) ? [guestPurple] : [];
  Future<void> _loadLessons() async {
    final generation = ++_lessonRequest;
    if (_group == null) return;
    final group = _group!['id'] as String;
    final from = _date(_monday);
    setState(() {
      _lessonsLoading = true;
      _lessonsError = null;
      _lessons = [];
    });
    try {
      final rows = await _service
          .rpc('get_guest_lessons', {'p_group': group, 'p_from': from});
      if (mounted && generation == _lessonRequest)
        setState(() => _lessons = rows);
    } catch (_) {
      if (mounted && generation == _lessonRequest)
        setState(() => _lessonsError =
            'Не удалось загрузить расписание. Повтори попытку.');
    } finally {
      if (mounted && generation == _lessonRequest)
        setState(() => _lessonsLoading = false);
    }
  }

  Future<void> _chooseGroup() async {
    if (_groupPickerOpen) return;
    _groupPickerOpen = true;
    try {
      final groups = await _service.rpc('get_guest_groups');
      if (!mounted) return;
      final separators = RegExp(r'[\s()\-–—]+');
      String normalize(String value) =>
          value.toLowerCase().replaceAll(separators, '');
      var query = '';
      final chosen = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        showDragHandle: true,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheetState) {
            final matches = groups.where((group) {
              return normalize(group['name'] as String).contains(query);
            }).toList();
            final theme = Theme.of(context);
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SafeArea(
                top: false,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .72,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Text('Выбери свою группу',
                            style: theme.textTheme.titleLarge),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: TextField(
                          onChanged: (value) => setSheetState(() {
                            query = normalize(value);
                          }),
                          decoration: const InputDecoration(
                            labelText: 'Найти группу',
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                        ),
                      ),
                      if (matches.isEmpty)
                        ListTile(
                          title: Text(
                            groups.isEmpty
                                ? 'Доступных групп пока нет'
                                : 'Группы не найдены',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      for (final group in matches)
                        ListTile(
                          title: Text(group['name'] as String),
                          selected: group['id'] == _group?['id'],
                          trailing: group['id'] == _group?['id']
                              ? const Icon(Icons.check)
                              : null,
                          onTap: () => Navigator.pop(context, group),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
      if (chosen == null || !mounted) return;
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('guest_selected_group_v1', jsonEncode(chosen)))
        throw StateError('save');
      if (!mounted) return;
      setState(() => _group = chosen);
      unawaited(_loadLessons());
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Не удалось выбрать или сохранить группу. Повтори попытку.')));
    } finally {
      _groupPickerOpen = false;
    }
  }

  Future<void> _login() async {
    if (_accountScreenOpen) return;
    _accountScreenOpen = true;
    try {
      await GuestAccountScreen.open(context);
    } finally {
      _accountScreenOpen = false;
    }
  }

  void _tab(MainTab tab) => MainTabScope.switchToTab(context, tab);
  void _info(String title, String body) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            SelectableText(body)
          ])));
  void _showNewsFeed(
    List<Map<String, dynamic>> rows,
    List<StudentHomeNews> presentation,
    int initialIndex,
  ) {
    if (presentation.isEmpty ||
        initialIndex < 0 ||
        initialIndex >= presentation.length) {
      return;
    }
    final byId = {for (final row in rows) (row['id'] ?? '').toString(): row};
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) => StudentNewsStorySheet(
        news: presentation,
        initialIndex: initialIndex,
        resolveImage: (item) async {
          final row = byId[item.id];
          if (row == null) return item.imageBytes;
          try {
            return await _service.image(row);
          } catch (_) {
            return null;
          }
        },
      ),
    );
  }

  Widget _loginStrip(String title, String subtitle) => GuestActionTile(
      title: title,
      subtitle: subtitle,
      icon: Icons.school_outlined,
      onTap: _login);
  Widget _home() {
    // The tap index must refer to the same snapshot that produced the cards,
    // even if a refresh replaces the backing list before the next frame.
    final rows = [for (final row in _news) Map<String, dynamic>.from(row)];
    final presentation = [for (final row in rows) _presentation(row)];
    return Column(children: [
      if (_newsFailed)
        MaterialBanner(
            content: const Text('Новости временно недоступны'),
            actions: [
              TextButton(onPressed: _loadNews, child: const Text('Повторить'))
            ]),
      Expanded(
          child: StudentHomeView(
              guest: true,
              hideHomePromo: true,
              data: StudentHomeData(
                  profile: StudentHomeProfile(
                      name: '', groupName: _group?['name'] ?? ''),
                  currentDate: DateTime.now(),
                  lessons: const [],
                  assignments: const [],
                  scheduleStatus: _group == null
                      ? 'Выбери свою группу'
                      : 'Расписание ${_group!['name']}',
                  assignmentsStatus:
                      'Задания твоих команд появятся после входа.',
                  news: presentation),
              onRefresh: _loadNews,
              onNotificationsTap: _login,
              onNewsTap: (index) => _showNewsFeed(rows, presentation, index),
              onSummaryTap: () => _tab(MainTab.schedule),
              onAssignmentsOpen: _login)),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => context.go('/login'),
            icon: const Icon(Icons.login_rounded),
            label: const Text('Войти'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
            ),
          ),
        ),
      ),
    ]);
  }

  StudentHomeNews _presentation(Map<String, dynamic> row) {
    final n = mapPublishedNews(row);
    return StudentHomeNews(
        id: n.id,
        title: n.title,
        subtitle: n.subtitle,
        body: n.body,
        icon: n.icon,
        gradientColors: n.gradientColors,
        variant: n.variant,
        imageBytes: _images[n.id],
        imageFocus: n.imageFocus,
        overlayDarken: n.overlayDarken,
        publishedAt: n.publishedAt);
  }

  Widget _learning() => Padding(
      padding: const EdgeInsets.all(20),
      child: GuestPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Учись вместе со своей группой',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        const Text(
            'В командах собраны чаты предметов, задания и вложения. Аккаунт нужен, чтобы видеть свои команды, общаться и следить за сроками.'),
        const SizedBox(height: 20),
        FilledButton(
            onPressed: _login,
            child: const Text('Войти или зарегистрироваться')),
        TextButton(
            onPressed: () => _tab(MainTab.info),
            child: const Text('Материалы без входа — в Базе')),
      ])));
  Widget _calendar() => MiniCalendar(
      weekDays: List.generate(7, (i) => _monday.add(Duration(days: i))),
      selectedDay: _day,
      weekMode: _weekMode,
      weekLabel:
          '${_monday.day}.${_monday.month}–${_monday.add(const Duration(days: 6)).day}.${_monday.add(const Duration(days: 6)).month}',
      weekYearLabel: '${_day.year}',
      eventColors: _eventColors,
      onPrevWeek: () => _selectDay(_day.subtract(const Duration(days: 7))),
      onNextWeek: () => _selectDay(_day.add(const Duration(days: 7))),
      onSelect: _selectDay);
  Widget _schedule() => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GuestActionTile(
            title: _group?['name'] ?? 'Выбрать группу',
            subtitle: 'Расписание без регистрации',
            icon: Icons.groups_outlined,
            onTap: _chooseGroup,
            trailing: const Icon(Icons.expand_more)),
        if (_lessonsLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: Text('Загружаем расписание…')),
          ),
        if (_lessonsError != null)
          TextButton(onPressed: _loadLessons, child: Text(_lessonsError!)),
        for (final l
            in _lessons.where((l) => _weekMode || l['date'] == _date(_day)))
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: GuestPanel(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        '${l['date']} · ${l['time_start'].toString().substring(0, 5)}–${l['time_end'].toString().substring(0, 5)}',
                        style: const TextStyle(
                            color: guestPurple, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(l['subject'] ?? '',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    Text(l['room'] ?? ''),
                  ]))),
        if (!_lessonsLoading &&
            _lessonsError == null &&
            !_lessons.any((l) => _weekMode || l['date'] == _date(_day)))
          SizedBox(
              height: 270,
              child: StudentScheduleEmptyState(
                  message: _group == null
                      ? 'Выбери группу, чтобы открыть расписание.'
                      : 'На выбранные даты занятий в базе нет.',
                  animate: false)),
        _loginStrip('Личный дневник и команды',
            'Войди, чтобы пользоваться личными учебными разделами'),
      ]));
  Widget _profile() => Theme(
      data: guestPresentationTheme(Theme.of(context)),
      child: Builder(
          builder: (context) => Scaffold(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              extendBodyBehindAppBar: true,
              appBar: AppBar(
                  systemOverlayStyle:
                      Theme.of(context).appBarTheme.systemOverlayStyle,
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  leading: IconButton(
                      icon: const Icon(Icons.info_outline),
                      onPressed: () =>
                          _info('Гостевой режим', 'Выбранная группа сохраняется после закрытия приложения. Аккаунт открывает личные учебные разделы.')),
                  actions: [
                    IconButton(
                        tooltip: 'Войти',
                        icon: const Icon(Icons.login),
                        onPressed: _login)
                  ]),
              body: StudentProfileScreenPreview(
                  guest: true,
                  showDiary: false,
                  displayName: 'Гостевой режим',
                  groupLabel: _group?['name'] ?? '',
                  padding: EdgeInsets.fromLTRB(
                      16, MediaQuery.paddingOf(context).top + kToolbarHeight - 16, 16, 24),
                  onMessagesTap: _login,
                  onFriendsTap: _login,
                  onReviewsTap: _login,
                  onMapTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapSpbgasuScreen())),
                  footer: FilledButton(onPressed: _login, child: const Text('Продолжить с аккаунтом'))))));
  @override
  Widget build(BuildContext context) {
    final height =
        (MediaQuery.paddingOf(context).top + 86.0).clamp(128.0, 150.0);
    const months = [
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
    final Widget body;
    if (!_ready) {
      body = const Center(child: ProductLoadingIndicator.page());
    } else if (widget.tab == 0) {
      body = _home();
    } else if (widget.tab == 1) {
      final group = _group;
      body = GuestInfoScreen(
        service: _service,
        onAccountInfo: _login,
        onChooseGroup: _chooseGroup,
        group: group == null
            ? null
            : (id: group['id'] as String, name: group['name'] as String),
      );
    } else if (widget.tab == 4) {
      body = _profile();
    } else {
      final header = switch (widget.tab) {
        2 => StudentLearningHeader(
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: 'О командах',
                icon: const Icon(Icons.info_outline),
                onPressed: () => _info('Команды',
                    'Войди, чтобы открыть команды, чаты и задания своей группы.')),
            IconButton(
                tooltip: 'Команды после входа',
                icon: const Icon(Icons.grid_view_rounded),
                onPressed: _login),
          ])),
        _ => StudentScheduleHeader(
            title: 'Расписание',
            subtitle: '${months[_day.month - 1]} ${_day.year}',
            day: _day,
            eventColors: _eventColors,
            onDatePicked: _selectDay,
            menuBuilder: (_) => StudentScheduleMenu(
                weekMode: _weekMode,
                onSelected: (v) => setState(() {
                      if (v == 'today')
                        _day = DateUtils.dateOnly(DateTime.now());
                      if (v == 'view_week') _weekMode = true;
                      if (v == 'view_day') _weekMode = false;
                      _loadLessons();
                    }))),
      };
      body = Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: height, child: header),
            if (widget.tab == 3) ...[
              const SizedBox(height: 12),
              _calendar(),
              CalendarLegend(items: {guestPurple: 'Занятия'}),
              const Divider(height: 1),
            ],
            Expanded(
                child: ListView(
                    key: ValueKey(widget.tab),
                    padding: EdgeInsets.zero,
                    children: [
                  switch (widget.tab) { 2 => _learning(), _ => _schedule() }
                ])),
          ]));
    }
    return body;
  }
}
