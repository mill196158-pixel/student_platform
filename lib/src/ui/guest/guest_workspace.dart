import 'dart:convert';
import 'package:lottie/lottie.dart';
import 'package:student_ui/student_ui.dart';
import 'guest_surface.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../navigation/main_tab_scope.dart';
import '../schedule/widgets/mini_calendar.dart';

/// Device-only workspace. Never reads an account cache or creates a backend client.
class GuestWorkspace extends StatefulWidget {
  const GuestWorkspace({super.key, required this.tab, this.saveSnapshot});
  final Future<bool> Function(String)? saveSnapshot;
  final int tab;
  @override
  State<GuestWorkspace> createState() => _GuestWorkspaceState();
}

class _GuestWorkspaceState extends State<GuestWorkspace> {
  static const storageKey = 'guest_workspace_v1';
  final _search = TextEditingController();
  List<Map<String, dynamic>> _notes = [], _plans = [];
  Set<String> _favorites = {};
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  bool _ready = false;
  bool _favoritesOnly = false;
  bool _saving = false;
  static const materials = <String, String>{
    'Производная: правило произведения':
        'Если u(x) и v(x) дифференцируемы, (uv)′ = u′v + uv′.\n\nПример: f(x) = x² sin x. Тогда f′(x) = 2x sin x + x² cos x.\n\nПроверь себя: найди производную x³ cos x. Ответ: 3x² cos x − x³ sin x.',
    'Единицы давления':
        '1 Па = 1 Н/м².\n1 кПа = 1 000 Па.\n1 МПа = 1 000 000 Па.\n1 бар = 100 000 Па.\n\nПример: 250 кПа = 0,25 МПа = 2,5 бар. Перед подстановкой в формулу приведи все величины к согласованной системе единиц.',
    'Как подготовить конспект':
        '1. Сформулируй вопрос темы.\n2. Запиши определения и условия применения формул.\n3. Разбери один пример по шагам.\n4. Отметь непонятные места.\n5. Закрой конспект и воспроизведи решение самостоятельно.\n\nДобавь собственные заметки во вкладке «Профиль».',
  };
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null) {
        final data = jsonDecode(raw) as Map;
        List<Map<String, dynamic>> validRows(Object? value) => value is List
            ? value
                .whereType<Map>()
                .where((row) =>
                    ['id', 'title', 'body', 'date']
                        .every((k) => row[k] is String) &&
                    DateTime.tryParse(row['date'] as String) != null)
                .map((row) => Map<String, dynamic>.from(row))
                .toList()
            : [];
        _notes = validRows(data['notes']);
        _plans = validRows(data['plans']);
        _favorites =
            (data['favorites'] as List? ?? []).whereType<String>().toSet();
      }
    } catch (_) {/* Keep an empty local workspace if old storage is invalid. */}
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(
        {'notes': _notes, 'plans': _plans, 'favorites': _favorites.toList()});
    final ok = await (widget.saveSnapshot?.call(encoded) ??
        prefs.setString(storageKey, encoded));
    if (!ok) throw StateError('storage');
  }

  Future<void> _change(VoidCallback action) async {
    if (_saving) return;
    final oldNotes = List<Map<String, dynamic>>.from(_notes);
    final oldPlans = List<Map<String, dynamic>>.from(_plans);
    final oldFavorites = Set<String>.from(_favorites);
    setState(() {
      _saving = true;
      action();
    });
    try {
      await _save();
    } catch (_) {
      if (mounted)
        setState(() {
          _notes = oldNotes;
          _plans = oldPlans;
          _favorites = oldFavorites;
        });
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Не удалось сохранить на устройстве. Повторите действие.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _login() => context.go('/login');
  void _tab(MainTab tab) => MainTabScope.switchToTab(context, tab);
  Widget _card(String title, String subtitle, IconData icon, VoidCallback tap,
          {Widget? trailing, List<Color>? colors}) =>
      GuestActionTile(
          title: title,
          subtitle: subtitle,
          icon: icon,
          onTap: tap,
          trailing: trailing,
          colors: colors);

  void _info(String title, String body) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Text(body, style: const TextStyle(height: 1.5)),
              ])));

  Widget _heading(String title, {String? subtitle}) => Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
        if (subtitle != null)
          Text(subtitle,
              style: const TextStyle(fontSize: 12, color: Color(0xFF747581))),
      ]));

  Widget _loginStrip(String title, String subtitle) => GuestPanel(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        const Icon(Icons.school_outlined, color: guestPurple),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          const SizedBox(height: 3),
          Text(subtitle,
              style: const TextStyle(fontSize: 12, color: Color(0xFF747581))),
        ])),
        TextButton(onPressed: _login, child: const Text('Войти'))
      ]));

  Future<void> _edit({bool plan = false, Map<String, dynamic>? entry}) async {
    if (_saving) return;
    final title = TextEditingController(text: entry?['title'] as String?);
    final body = TextEditingController(text: entry?['body'] as String?);
    final result = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(
                    plan ? 'План на ${_day.day}.${_day.month}' : 'Моя заметка'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: title,
                      maxLength: 100,
                      decoration: const InputDecoration(labelText: 'Название')),
                  TextField(
                      controller: body,
                      maxLength: 5000,
                      minLines: 3,
                      maxLines: 6,
                      decoration: InputDecoration(
                          labelText: plan
                              ? 'Время, аудитория, подробности'
                              : 'Текст заметки'))
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Отмена')),
                  FilledButton(
                      onPressed: () {
                        if (title.text.trim().isNotEmpty)
                          Navigator.pop(ctx, true);
                      },
                      child: const Text('Сохранить'))
                ]));
    if (result == true && mounted)
      await _change(() {
        final row = <String, dynamic>{
          'id':
              entry?['id'] ?? DateTime.now().microsecondsSinceEpoch.toString(),
          'title': title.text.trim(),
          'body': body.text.trim(),
          'date': entry?['date'] ?? _day.toIso8601String()
        };
        final list = plan ? _plans : _notes;
        final index = list.indexWhere((e) => e['id'] == row['id']);
        if (index < 0) {
          list.add(row);
        } else {
          list[index] = row;
        }
      });
    // Dialog route finishes its dismissal animation before releasing controllers.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    title.dispose();
    body.dispose();
  }

  void _article(String title) => Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => Scaffold(
              appBar: AppBar(title: Text(title)),
              body: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText(materials[title]!,
                      style: const TextStyle(fontSize: 18, height: 1.6))))));
  List<Widget> _catalog(
          {bool favoritesOnly = false, bool applySearch = true}) =>
      [
        for (final entry in materials.entries.where((e) =>
            (!favoritesOnly || _favorites.contains(e.key)) &&
            (!applySearch ||
                e.key.toLowerCase().contains(_search.text.toLowerCase()))))
          _card(entry.key, 'Материал · без сети', Icons.menu_book_outlined,
              () => _article(entry.key),
              colors: materials.keys.first == entry.key
                  ? const [Color(0xFFE4F0FF), Color(0xFFDCEAFF)]
                  : const [Color(0xFFEDE5FC), Color(0xFFF2ECFC)],
              trailing: IconButton(
                  tooltip: 'В избранное',
                  icon: Icon(
                      _favorites.contains(entry.key)
                          ? Icons.star
                          : Icons.star_border,
                      color: guestPurple),
                  onPressed: () => _change(() {
                        if (!_favorites.add(entry.key))
                          _favorites.remove(entry.key);
                      }))),
        if (favoritesOnly && _favorites.isEmpty)
          const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Добавь материалы в избранное во вкладке «База».')),
        if (!favoritesOnly &&
            !materials.keys.any(
                (t) => t.toLowerCase().contains(_search.text.toLowerCase())))
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Материалы не найдены. Попробуй другой запрос.')),
      ];

  Widget _home() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            child: Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('Привет! 👋',
                        style: TextStyle(
                            fontSize: 25, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    const Text('Без регистрации',
                        style: TextStyle(color: Color(0xFF747581))),
                  ])),
              IconButton.filledTonal(
                  tooltip: 'Твоё пространство',
                  onPressed: () => _tab(MainTab.profile),
                  style: IconButton.styleFrom(backgroundColor: Colors.white),
                  icon: const Icon(Icons.person_outline, color: guestPurple)),
            ])),
        StudentHomeNewsFeed(
            news: const [
              StudentHomeNews(
                  id: 'guest-welcome',
                  title: 'Твоя учёба',
                  subtitle: 'Начни здесь',
                  body: '',
                  icon: Icons.auto_stories_rounded,
                  gradientColors: [Color(0xFFE6DCFF), Color(0xFFC8E8E4)])
            ],
            onNewsTap: (_) => _info('Добро пожаловать',
                'Открывай материалы в Базе, сохраняй избранное и веди заметки на устройстве. Команды, задания и чаты предметов появятся после входа.')),
        Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GuestPanel(
                      colors: guestBlend,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(children: [
                              Icon(Icons.auto_awesome, color: guestPurple),
                              SizedBox(width: 12),
                              Text('Сводка дня',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF676575)))
                            ]),
                            const SizedBox(height: 14),
                            const Text('Учись в своём ритме',
                                style: TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 4),
                            const Text(
                                'Материалы, заметки и твой план — под рукой.',
                                style: TextStyle(fontSize: 13)),
                            const SizedBox(height: 12),
                            _card(
                                'Мой план',
                                'Запланируй подготовку на сегодня',
                                Icons.calendar_today_outlined,
                                () => _tab(MainTab.schedule)),
                          ])),
                  const SizedBox(height: 14),
                  _heading('Полезное для учёбы',
                      subtitle: 'Открытые материалы'),
                  GuestPanel(
                      colors: const [Color(0xFFFFF3DC), Color(0xFFE4F5EF)],
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
                      child: Column(children: [
                        _card(
                            'Конспекты и примеры',
                            'Формулы и разборы задач',
                            Icons.description_outlined,
                            () => _tab(MainTab.info)),
                        _card(
                            'Как подготовить конспект',
                            'Короткая памятка',
                            Icons.school_outlined,
                            () => _article('Как подготовить конспект')),
                      ])),
                  const SizedBox(height: 14),
                  _card('Мои заметки', 'Сохраняй важное на этом устройстве',
                      Icons.edit_note, () => _tab(MainTab.profile),
                      colors: guestBlend),
                  _loginStrip('Учись вместе с группой',
                      'Команды и чаты предметов после входа'),
                ])),
      ]);

  Widget _base() => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Найти материал',
                filled: true,
                fillColor: Colors.white,
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: const BorderSide(color: Color(0xFFE4DDF4))),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: const BorderSide(color: Color(0xFFE4DDF4))))),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
              child: ChoiceChip(
                  shape: const StadiumBorder(),
                  showCheckmark: false,
                  label: const Center(child: Text('Все материалы')),
                  selected: !_favoritesOnly,
                  onSelected: (_) => setState(() => _favoritesOnly = false))),
          const SizedBox(width: 8),
          Expanded(
              child: ChoiceChip(
                  shape: const StadiumBorder(),
                  showCheckmark: false,
                  label: const Center(child: Text('Избранное')),
                  selected: _favoritesOnly,
                  onSelected: (_) => setState(() => _favoritesOnly = true)))
        ]),
        const SizedBox(height: 12),
        GuestPanel(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              _heading(
                  _favoritesOnly ? 'Избранные материалы' : 'Каталог материалов',
                  subtitle: 'Стартовая подборка · доступна без сети'),
              ..._catalog(favoritesOnly: _favoritesOnly),
            ])),
        const SizedBox(height: 12),
        _loginStrip(
            'Учебный план после входа', 'Твои дисциплины, зачёты и прогресс'),
      ]));

  Widget _learning() => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GuestPanel(
            colors: guestBlend,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.forum_outlined, color: guestPurple, size: 36),
              const SizedBox(height: 16),
              const Text('Твоя группа — рядом',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('Войди, чтобы открыть свои команды и чаты предметов.',
                  style: TextStyle(height: 1.5)),
              const SizedBox(height: 16),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                      onPressed: _login,
                      icon: const Icon(Icons.login),
                      label: const Text('Войти в команды'))),
            ])),
        const SizedBox(height: 18),
        _heading('После входа'),
        _card('Команды', 'Учебные группы и совместная работа',
            Icons.groups_outlined, _login),
        _card('Чаты предметов', 'Обсуждения и вложения в одном месте',
            Icons.chat_bubble_outline, _login),
        _card('Задания', 'Сроки, темы и задачи твоих команд',
            Icons.assignment_outlined, _login),
        const SizedBox(height: 8),
        TextButton(
            onPressed: () => _tab(MainTab.info),
            child: const Text('Материалы без входа — в Базе')),
      ]));

  Widget _schedule() {
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    final plans =
        _plans.where((p) => p['date'] == _day.toIso8601String()).toList();
    return Padding(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          MiniCalendar(
              weekDays: List.generate(7, (i) => monday.add(Duration(days: i))),
              selectedDay: _day,
              eventColors: (d) =>
                  _plans.any((p) => p['date'] == d.toIso8601String())
                      ? [guestPurple]
                      : [],
              onPrevWeek: () =>
                  setState(() => _day = _day.subtract(const Duration(days: 7))),
              onNextWeek: () =>
                  setState(() => _day = _day.add(const Duration(days: 7))),
              onSelect: (d) => setState(() => _day = d)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
                child: _heading('Мой план',
                    subtitle:
                        '${_day.day}.${_day.month}.${_day.year} · на устройстве')),
            TextButton.icon(
                onPressed: () => _edit(plan: true),
                icon: const Icon(Icons.add),
                label: const Text('Добавить в план'))
          ]),
          for (final plan in plans)
            _card(plan['title'] as String, plan['body'] as String, Icons.event,
                () => _edit(plan: true, entry: plan),
                colors: guestBlend,
                trailing: IconButton(
                    tooltip: 'Удалить из плана',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _change(() => _plans.remove(plan)))),
          if (plans.isEmpty) ...[
            Lottie.asset('assets/lottie/cat_sleeping.json',
                height: 150, animate: false),
            const Center(
                child: Text('На этот день планов нет.',
                    style: TextStyle(fontWeight: FontWeight.w700))),
            const SizedBox(height: 6),
            const Center(
                child: Text('Можно отдохнуть или наметить подготовку.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Color(0xFF747581)))),
            const SizedBox(height: 28),
          ],
          _loginStrip('Расписание группы',
              'Автоматическое расписание доступно после входа'),
        ]));
  }

  Widget _profile() => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
                tooltip: 'О гостевом режиме',
                icon: const Icon(Icons.tune),
                onPressed: () => _info('На этом устройстве',
                    'Избранное, заметки и план сохраняются только здесь. После удаления приложения они могут быть потеряны. С аккаунтом автоматически не объединяются.'))),
        const Center(
            child: CircleAvatar(
                radius: 42,
                backgroundColor: Color(0xFFE2D9F7),
                child: Icon(Icons.person, size: 54, color: guestPurple))),
        const SizedBox(height: 12),
        const Text('Гостевой режим',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('Без аккаунта',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF747581))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _login, child: const Text('Войти')),
        const SizedBox(height: 6),
        OutlinedButton(
            onPressed: _login, child: const Text('Вход и регистрация')),
        const SizedBox(height: 16),
        GuestPanel(
            colors: const [Color(0xFFFFF3DC), Color(0xFFE0F3EF)],
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Твоё пространство',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('Сохраняй полезное и готовься к занятиям.'),
              TextButton(
                  onPressed: () => _tab(MainTab.info),
                  child: const Text('Открыть материалы')),
            ])),
        const SizedBox(height: 14),
        _heading('На этом устройстве',
            subtitle: 'Без синхронизации с аккаунтом'),
        _card('Мой план', 'Дела и подготовка к занятиям',
            Icons.calendar_month_outlined, () => _tab(MainTab.schedule),
            colors: guestBlend),
        _card('Добавить заметку', 'Запиши идею или разбор задачи',
            Icons.edit_note, () => _edit(),
            colors: guestBlend),
        for (final note in _notes)
          _card(note['title'] as String, note['body'] as String, Icons.notes,
              () => _edit(entry: note),
              trailing: IconButton(
                  tooltip: 'Удалить заметку',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _change(() => _notes.remove(note)))),
        _heading('Избранное'),
        ..._catalog(favoritesOnly: true, applySearch: false),
      ]));

  @override
  Widget build(BuildContext context) {
    final headers = <(String, String, IconData)>[
      ('', '', Icons.home),
      ('База', 'Открытые материалы', Icons.lightbulb_outline_rounded),
      ('Команды', 'Чаты и задания', Icons.groups_outlined),
      ('Расписание', 'Личный план', Icons.calendar_month_outlined),
    ];
    final theme = Theme.of(context);
    return Theme(
        data: theme.copyWith(
          brightness: Brightness.light,
          colorScheme: ColorScheme.fromSeed(seedColor: guestPurple),
          textTheme: theme.textTheme
              .apply(bodyColor: guestInk, displayColor: guestInk),
        ),
        child: AbsorbPointer(
            absorbing: _saving,
            child: ColoredBox(
                color: const Color(0xFFFAF8FC),
                child: SafeArea(
                    child: ListView(
                        key: ValueKey(widget.tab),
                        padding: EdgeInsets.zero,
                        children: [
                      if (widget.tab > 0 && widget.tab < 4)
                        GuestSectionHeader(
                            title: headers[widget.tab].$1,
                            subtitle: headers[widget.tab].$2,
                            icon: headers[widget.tab].$3,
                            onInfo: () => _info(
                                headers[widget.tab].$1,
                                widget.tab == 1
                                    ? 'Стартовые материалы доступны без регистрации и интернета. Сохраняй нужное в избранное.'
                                    : widget.tab == 2
                                        ? 'Команды, чаты и задания относятся к твоему аккаунту и доступны после входа.'
                                        : 'Здесь можно вести личный план на устройстве. Расписание учебной группы доступно после входа.')),
                      if (!_ready)
                        const LinearProgressIndicator()
                      else
                        switch (widget.tab) {
                          0 => _home(),
                          1 => _base(),
                          2 => _learning(),
                          3 => _schedule(),
                          _ => _profile()
                        },
                    ])))));
  }
}
