import 'dart:convert';
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
          {Widget? trailing}) =>
      Card(
          margin: const EdgeInsets.only(bottom: 12),
          color: const Color(0xfff5effb),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              leading: CircleAvatar(
                  backgroundColor: const Color(0xffe8ddfa),
                  child: Icon(icon, color: const Color(0xff7050ac))),
              title: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(subtitle),
              trailing: trailing ?? const Icon(Icons.chevron_right),
              onTap: tap));
  Widget _banner(String title, String body, VoidCallback tap) => Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
              colors: [Color(0xffded0fa), Color(0xffc4eee4)])),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(body),
        const SizedBox(height: 8),
        TextButton(onPressed: tap, child: const Text('Открыть'))
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
  List<Widget> _catalog({bool favoritesOnly = false}) => [
        if (!favoritesOnly)
          TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search), hintText: 'Найти материал')),
        const SizedBox(height: 16),
        for (final title in materials.keys.where((t) =>
            (!favoritesOnly || _favorites.contains(t)) &&
            t.toLowerCase().contains(_search.text.toLowerCase())))
          _card(title, 'Встроенный материал · доступен без сети',
              Icons.menu_book, () => _article(title),
              trailing: IconButton(
                  tooltip: 'В избранное',
                  icon: Icon(_favorites.contains(title)
                      ? Icons.star
                      : Icons.star_border),
                  onPressed: () => _change(() {
                        if (!_favorites.add(title)) _favorites.remove(title);
                      }))),
        if (favoritesOnly && _favorites.isEmpty)
          const Text('Добавь материалы в избранное во вкладке «База».'),
      ];
  @override
  Widget build(BuildContext context) {
    final titles = [
      'Привет! 👋',
      'База',
      'Обучение',
      'Расписание',
      'Гостевой режим'
    ];
    final subtitles = [
      'Без регистрации',
      'Открытые материалы',
      'Команды и чаты предметов',
      'Личный план на устройстве',
      'Без аккаунта'
    ];
    final monday = _day.subtract(Duration(days: _day.weekday - 1));
    return AbsorbPointer(
        absorbing: _saving,
        child: SafeArea(
            child: ListView(
                key: ValueKey(widget.tab),
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
                children: [
              Row(children: [
                Expanded(
                    child: Text(titles[widget.tab],
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.bold))),
                TextButton(onPressed: _login, child: const Text('Войти'))
              ]),
              Text(subtitles[widget.tab]),
              const SizedBox(height: 24),
              if (!_ready)
                const LinearProgressIndicator()
              else ...[
                if (widget.tab == 0) ...[
                  _banner(
                      'Всё для самостоятельной учёбы',
                      'Материалы, заметки и план — без аккаунта. Личные команды и чаты доступны после входа.',
                      () => _tab(MainTab.info)),
                  _card('Открытые материалы', 'Найти и сохранить в избранное',
                      Icons.menu_book, () => _tab(MainTab.info)),
                  _card('Команды и чаты', 'Доступ после входа',
                      Icons.groups_outlined, () => _tab(MainTab.learning)),
                  _card('Расписание', 'Составить свой план на устройстве',
                      Icons.calendar_month, () => _tab(MainTab.schedule)),
                ],
                if (widget.tab == 1) ..._catalog(),
                if (widget.tab == 2) ...[
                  const Center(
                      child: Icon(Icons.groups_outlined,
                          size: 72, color: Color(0xff7050ac))),
                  const SizedBox(height: 24),
                  _banner(
                      'Команды и чаты предметов',
                      'Войди в аккаунт, чтобы видеть свои учебные команды, обсуждать предметы и работать с заданиями.',
                      _login),
                  FilledButton.icon(
                      onPressed: _login,
                      icon: const Icon(Icons.login),
                      label: const Text('Войти в команды')),
                  const SizedBox(height: 16),
                  TextButton(
                      onPressed: () => _tab(MainTab.info),
                      child: const Text('Материалы без входа — в Базе')),
                ],
                if (widget.tab == 3) ...[
                  MiniCalendar(
                      weekDays: List.generate(
                          7, (i) => monday.add(Duration(days: i))),
                      selectedDay: _day,
                      eventColors: (d) =>
                          _plans.any((p) => p['date'] == d.toIso8601String())
                              ? [Colors.purple]
                              : [],
                      onPrevWeek: () => setState(
                          () => _day = _day.subtract(const Duration(days: 7))),
                      onNextWeek: () => setState(
                          () => _day = _day.add(const Duration(days: 7))),
                      onSelect: (d) => setState(() => _day = d)),
                  const SizedBox(height: 16),
                  const Text(
                      'Это твой локальный план. Автоматическое расписание группы пока доступно после входа.'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                      onPressed: () => _edit(plan: true),
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить в план')),
                  const SizedBox(height: 16),
                  for (final plan in _plans
                      .where((p) => p['date'] == _day.toIso8601String()))
                    _card(plan['title'] as String, plan['body'] as String,
                        Icons.event, () => _edit(plan: true, entry: plan),
                        trailing: IconButton(
                            tooltip: 'Удалить из плана',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () =>
                                _change(() => _plans.remove(plan)))),
                  if (!_plans.any((p) => p['date'] == _day.toIso8601String()))
                    const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('На этот день планов нет.')),
                ],
                if (widget.tab == 4) ...[
                  const Center(
                      child: CircleAvatar(
                          radius: 45,
                          child: Icon(Icons.person_outline, size: 48))),
                  const SizedBox(height: 20),
                  _banner(
                      'Твоё пространство',
                      'Избранное, заметки и план хранятся на устройстве. После удаления приложения могут быть потеряны. С аккаунтом автоматически не объединяются.',
                      _login),
                  FilledButton.icon(
                      onPressed: () => _edit(),
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить заметку')),
                  for (final note in _notes)
                    _card(note['title'] as String, note['body'] as String,
                        Icons.notes, () => _edit(entry: note),
                        trailing: IconButton(
                            tooltip: 'Удалить заметку',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () =>
                                _change(() => _notes.remove(note)))),
                  Text('Избранное',
                      style: Theme.of(context).textTheme.titleLarge),
                  ..._catalog(favoritesOnly: true),
                ],
              ],
            ])));
  }
}
