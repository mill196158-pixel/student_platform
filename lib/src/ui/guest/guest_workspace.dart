import 'dart:convert';
import 'package:student_ui/student_ui.dart';
import 'guest_surface.dart';
import '../shared/student_section_headers.dart';
import '../info/info_screen.dart' show InfoSubjectCard;
import '../info/useful_subject.dart';
import '../learning/learning_screen.dart' show StudentTeamTile;
import '../learning/models/team.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _notesKey = GlobalKey();
  List<Map<String, dynamic>> _notes = [], _plans = [];
  Set<String> _favorites = {};
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  bool _ready = false;
  bool _favoritesOnly = false;
  bool _weekMode = false;
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
          InfoSubjectCard(
              item: UsefulSubject(
                  id: entry.key,
                  title: entry.key,
                  controlForm: '',
                  description: entry.value,
                  teacherName: '',
                  teamName: '',
                  teamIcon: '',
                  teamGroupName: ''),
              onOpen: (_) => _article(entry.key),
              details: const Text('Материал · без сети',
                  style: TextStyle(fontSize: 12, color: Color(0xFF676575))),
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

  Widget _home() => StudentHomeView(
        guest: true,
        hideHomePromo: true,
        data: StudentHomeData(
            profile: const StudentHomeProfile(name: '', groupName: ''),
            currentDate: DateTime.now(),
            lessons: const [],
            scheduleStatus: 'Расписание твоей группы',
            assignmentsStatus: 'Добавь дела в свой план — они появятся здесь.',
            assignments: [
              for (final plan in _plans)
                StudentHomeAssignment(
                    id: plan['id'] as String,
                    title: plan['title'] as String,
                    subject: 'Мой план',
                    deadline:
                        '${DateTime.parse(plan['date'] as String).day}.${DateTime.parse(plan['date'] as String).month}',
                    dueAt: DateTime.parse(plan['date'] as String))
            ],
            news: const [
              StudentHomeNews(
                  id: 'guest-welcome',
                  title: 'Новое приложение',
                  subtitle: 'Добро пожаловать',
                  body: '',
                  icon: Icons.auto_stories_rounded,
                  gradientColors: [Color(0xFFE6DCFF), Color(0xFFC8E8E4)])
            ]),
        onNotificationsTap: _login,
        onNewsTap: (_) => _info('Добро пожаловать',
            'Материалы, заметки и личный план доступны без входа. Команды и чаты предметов — после авторизации.'),
        onSummaryTap: () => _tab(MainTab.schedule),
        onAssignmentsOpen: () => _tab(MainTab.schedule),
        onAssignmentTap: (item) => _edit(
            plan: true, entry: _plans.firstWhere((p) => p['id'] == item.id)),
      );

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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final item in const [
          ('Войти в команды', 'Твои учебные группы после входа', 'КМ'),
          ('Чаты предметов', 'Обсуждения и вложения после входа', 'ЧП'),
          ('Задания', 'Задачи и сроки твоих команд после входа', 'ЗД'),
        ]) ...[
          StudentTeamTile(
              Team(
                  id: 'guest-gate',
                  name: item.$1,
                  teacher: item.$2,
                  groupCode: '',
                  icon: item.$3),
              onTap: _login),
          const SizedBox(height: 12),
        ],
        TextButton(
            onPressed: () => _tab(MainTab.info),
            child: const Text('Материалы без входа — в Базе')),
      ]));

  Widget _calendar() {
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    return MiniCalendar(
        weekDays: List.generate(7, (i) => monday.add(Duration(days: i))),
        selectedDay: _day,
        weekMode: _weekMode,
        weekLabel:
            "${monday.day}.${monday.month}–${monday.add(const Duration(days: 6)).day}.${monday.add(const Duration(days: 6)).month}",
        weekYearLabel: "${_day.year}",
        eventColors: (d) => _plans.any((p) => p['date'] == d.toIso8601String())
            ? [guestPurple]
            : [],
        onPrevWeek: () =>
            setState(() => _day = _day.subtract(const Duration(days: 7))),
        onNextWeek: () =>
            setState(() => _day = _day.add(const Duration(days: 7))),
        onSelect: (d) => setState(() => _day = d));
  }

  Widget _schedule() {
    final plans = _plans.where((p) {
      final date = DateTime.parse(p['date'] as String);
      final monday = _day.subtract(Duration(days: _day.weekday - 1));
      return _weekMode
          ? !date.isBefore(monday) &&
              date.isBefore(monday.add(const Duration(days: 7)))
          : p['date'] == _day.toIso8601String();
    }).toList();
    return Padding(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
            SizedBox(
                height: 240,
                child: StudentScheduleEmptyState(
                    message: _weekMode ? 'На этой неделе планов нет.' : 'На этот день планов нет.', animate: false)),
            const SizedBox(height: 28),
          ],
          _loginStrip('Расписание группы',
              'Автоматическое расписание доступно после входа'),
        ]));
  }

  Widget _profile() => Scaffold(
        backgroundColor: const Color(0xFFFAF8FC),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
            systemOverlayStyle: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarBrightness: Brightness.light,
              statusBarIconBrightness: Brightness.dark,
            ),
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            leading: IconButton(
                tooltip: 'О гостевом режиме',
                icon: const Icon(Icons.tune),
                onPressed: () => _info('На этом устройстве',
                    'Избранное, заметки и план сохраняются только на этом устройстве. С аккаунтом автоматически не объединяются.')),
            actions: [
              IconButton(
                  tooltip: 'Обновить',
                  icon: const Icon(Icons.refresh),
                  onPressed: _load),
              IconButton(
                  tooltip: 'Войти',
                  icon: const Icon(Icons.logout),
                  onPressed: _login)
            ]),
        body: StudentProfileScreenPreview(
            guest: true,
            displayName: 'Гостевой режим',
            groupLabel: '',
            statusLabel: 'Без регистрации',
            padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + kToolbarHeight - 16,
                16,
                24),
            onMessagesTap: _login,
            onFriendsTap: _login,
            onReviewsTap: _login,
            onMapTap: _login,
            onDiaryTap: () {
              final c = _notesKey.currentContext;
              if (c != null)
                Scrollable.ensureVisible(c,
                    duration: const Duration(milliseconds: 200));
            },
            footer: Column(
                key: _notesKey,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _heading('На этом устройстве',
                      subtitle: 'Без синхронизации с аккаунтом'),
                  _card('Добавить заметку', 'Запиши идею или разбор задачи',
                      Icons.edit_note, () => _edit(),
                      colors: guestBlend),
                  for (final note in _notes)
                    _card(note['title'] as String, note['body'] as String,
                        Icons.notes, () => _edit(entry: note),
                        trailing: IconButton(
                            tooltip: 'Удалить заметку',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () =>
                                _change(() => _notes.remove(note)))),
                  _heading('Избранное'),
                  ..._catalog(favoritesOnly: true, applySearch: false),
                  TextButton(onPressed: _login, child: const Text('Войти')),
                ])),
      );

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
      body = const Center(child: CircularProgressIndicator());
    } else if (widget.tab == 0) {
      body = _home();
    } else if (widget.tab == 4) {
      body = _profile();
    } else {
      final header = switch (widget.tab) {
        1 => StudentInfoHeader(
            subtitle: 'Открытые материалы',
            onInfoTap: () => _info('База',
                'Стартовые материалы доступны без сети. Сохраняй нужное в избранное.'),
            onSectionTap: _login),
        2 => StudentLearningHeader(
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                tooltip: 'О командах',
                icon: const Icon(Icons.info_outline, color: Colors.black87),
                onPressed: () => _info('Команды',
                    'Войди, чтобы открыть команды, чаты и задания своей группы.')),
            IconButton(
                tooltip: 'Команды после входа',
                icon:
                    const Icon(Icons.grid_view_rounded, color: Colors.black87),
                onPressed: _login),
          ])),
        _ => StudentScheduleHeader(
            title: 'Расписание',
            subtitle: '${months[_day.month - 1]} ${_day.year}',
            day: _day,
            eventColors: (d) => _plans.any(
                    (p) => p['date'] == DateUtils.dateOnly(d).toIso8601String())
                ? [guestPurple]
                : [],
            onDatePicked: (d) => setState(() => _day = DateUtils.dateOnly(d)),
            menuBuilder: (_) => StudentScheduleMenu(
                weekMode: _weekMode,
                onSelected: (v) => setState(() {
                      if (v == 'today')
                        _day = DateUtils.dateOnly(DateTime.now());
                      if (v == 'view_week') _weekMode = true;
                      if (v == 'view_day') _weekMode = false;
                    }))),
      };
      body = Scaffold(
          backgroundColor: widget.tab == 1 ? const Color(0xFFF7F7FB) : null,
          body:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: height, child: header),
            if (widget.tab == 3) ...[
              const SizedBox(height: 12),
              _calendar(),
              CalendarLegend(items: {guestPurple: 'Мой план'}),
              const Divider(height: 1),
            ],
            Expanded(
                child: ListView(
                    key: ValueKey(widget.tab),
                    padding: EdgeInsets.zero,
                    children: [
                  switch (widget.tab) {
                    1 => _base(),
                    2 => _learning(),
                    _ => _schedule()
                  }
                ])),
          ]));
    }
    return AbsorbPointer(absorbing: _saving, child: body);
  }
}
