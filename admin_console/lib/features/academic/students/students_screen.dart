import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../teachers/teacher_import_service.dart';
import 'students_repository.dart';

class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key, required this.session, this.repository});
  final AdminSessionController session;
  final StudentsRepository? repository;
  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  late final StudentsRepository _repository =
      widget.repository ??
      (AdminBackendConfig.isDemoMode
          ? LocalStudentsRepository()
          : SupabaseStudentsRepository());
  List<StudentItem> _items = const [];
  List<GroupItem> _groups = const [];
  List<TermItem> _terms = const [];
  final Set<String> _selected = {};
  bool _loading = true;
  String _query = '';
  bool? _activeFilter = true;
  String? _groupFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _repository.listStudents(
          query: _query,
          active: _activeFilter,
          groupId: _groupFilter,
        ),
        _repository.listGroups(),
        _repository.listTerms(),
      ]);
      _items = results[0] as List<StudentItem>;
      _groups = results[1] as List<GroupItem>;
      _terms = results[2] as List<TermItem>;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit(StudentItem item) async {
    final name = TextEditingController(text: item.name);
    final surname = TextEditingController(text: item.surname);
    var active = item.isActive;
    String? groupId = item.primaryGroupId;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(item.login),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: surname,
                  decoration: const InputDecoration(labelText: 'Фамилия'),
                ),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Имя'),
                ),
                DropdownButtonFormField<String?>(
                  initialValue: groupId,
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Группа не выбрана'),
                    ),
                    ..._groups.map(
                      (g) => DropdownMenuItem(value: g.id, child: Text(g.name)),
                    ),
                  ],
                  onChanged: (v) => setLocal(() => groupId = v),
                  decoration: const InputDecoration(labelText: 'Группа'),
                ),
                SwitchListTile(
                  value: active,
                  onChanged: (v) => setLocal(() => active = v),
                  title: const Text('Активен'),
                ),
                const Text(
                  'Создание auth-пользователя в Web Admin недоступно '
                  '(без service_role). Импорт обновляет только существующих.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    await _repository.updateStudent(
      id: item.id,
      name: name.text.trim(),
      surname: surname.text.trim(),
      isActive: active,
    );
    if (groupId != null && groupId != item.primaryGroupId) {
      await _repository.assignGroup(userId: item.id, groupId: groupId!);
    }
    await _load();
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.first.bytes;
    if (bytes == null) return;
    final sheet = TeacherImportService().readFirstSheet(bytes);
    final mapping = suggestStudentHeaderMapping(sheet.headers);
    final rows = [for (final raw in sheet.rows) mapImportRow(raw, mapping)];
    final dry = await _repository.importDryRun(rows);
    if (!mounted) return;
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Dry-run студентов'),
        content: SizedBox(
          width: 520,
          height: 320,
          child: ListView(
            children: [
              for (final item in (dry['items'] as List? ?? const []))
                ListTile(
                  dense: true,
                  title: Text(
                    '${item['classification']} · ${item['payload']?['login'] ?? ''}',
                  ),
                  subtitle: Text(item['error_text']?.toString() ?? ''),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    if (apply != true) return;
    final result = await _repository.importApply(rows);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result['idempotent_replay'] == true
              ? 'Повтор: импорт уже применён'
              : 'Обновлено: ${result['updated'] ?? 0}',
        ),
      ),
    );
    await _load();
  }

  Future<void> _upsertGroup([GroupItem? existing]) async {
    final controller = TextEditingController(text: existing?.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(existing == null ? 'Новая группа' : 'Редактировать группу'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Название группы'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(existing == null ? 'Создать' : 'Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _repository.upsertGroup(id: existing?.id, name: name);
    await _load();
  }

  Future<void> _showJournal() async {
    final batches = await _repository.listOpsBatches();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Журнал операций'),
        content: SizedBox(
          width: 560,
          height: 360,
          child: batches.isEmpty
              ? const Center(child: Text('Операций пока нет'))
              : ListView(
                  children: [
                    for (final batch in batches)
                      ListTile(
                        title: Text('${batch['operation']} · ${batch['id']}'),
                        subtitle: Text('${batch['summary']}'),
                        trailing: TextButton(
                          onPressed: () async {
                            final rows = await _repository.listOpsRows(
                              '${batch['id']}',
                            );
                            if (!context.mounted) return;
                            await showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text('Строки · ${batch['id']}'),
                                content: SizedBox(
                                  width: 520,
                                  height: 300,
                                  child: ListView(
                                    children: [
                                      for (final row in rows)
                                        ListTile(
                                          dense: true,
                                          title: Text(
                                            '#${row['row_number']} · ${row['classification']}',
                                          ),
                                          subtitle: Text(
                                            row['error_text']?.toString() ?? '',
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Закрыть'),
                                  ),
                                ],
                              ),
                            );
                          },
                          child: const Text('Строки'),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _bulkSetActive(bool isActive) async {
    if (_selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isActive ? 'Массовое восстановление' : 'Массовая блокировка',
        ),
        content: Text(
          'Подтвердите действие для ${_selected.length} студентов.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.bulkSetActive(
      userIds: _selected.toList(),
      isActive: isActive,
    );
    _selected.clear();
    await _load();
  }

  Future<void> _prepareTerm(TermItem term) async {
    final dry = await _repository.prepareTermDryRun(term.id);
    if (!mounted) return;
    var setCurrent = false;
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('Подготовка семестра · ${term.label}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Групп: ${dry['groups_count'] ?? 0}'),
              Text('Недостающих offerings: ${dry['missing_offerings'] ?? 0}'),
              Text('Недостающих teams: ${dry['missing_teams'] ?? 0}'),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: setCurrent,
                onChanged: (v) => setLocal(() => setCurrent = v ?? false),
                title: const Text('Сделать текущим после apply'),
                subtitle: const Text(
                  'Переключение архивирует предметные чаты прошлого периода.',
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
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Подтвердить apply'),
            ),
          ],
        ),
      ),
    );
    if (apply != true) return;
    final result = await _repository.prepareTermApply(
      termId: term.id,
      setCurrent: setCurrent,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result['idempotent_replay'] == true
              ? 'Повтор: подготовка уже применена'
              : 'Offerings +${result['created_offerings'] ?? 0}, teams +${result['created_teams'] ?? 0}',
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final canWrite =
        widget.session.isLocalPrototype ||
        widget.session.capabilities.canWriteStudents;
    final canSuspend =
        widget.session.isLocalPrototype ||
        widget.session.capabilities.canSuspendStudents;
    final canGroups =
        widget.session.isLocalPrototype ||
        widget.session.capabilities.canWriteGroups;
    final canTerms =
        widget.session.isLocalPrototype ||
        widget.session.capabilities.canManageTerms;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Студенты, группы и семестры',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Управление профилями и enrollments. Auth-создание остаётся в CLI/Edge.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 320,
              child: TextField(
                onChanged: (v) {
                  _query = v;
                  _load();
                },
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Логин или ФИО',
                ),
              ),
            ),
            DropdownButton<bool?>(
              value: _activeFilter,
              items: const [
                DropdownMenuItem(value: null, child: Text('Все')),
                DropdownMenuItem(value: true, child: Text('Активные')),
                DropdownMenuItem(value: false, child: Text('Заблокированные')),
              ],
              onChanged: (v) {
                _activeFilter = v;
                _load();
              },
            ),
            DropdownButton<String?>(
              value: _groupFilter,
              hint: const Text('Все группы'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Все группы')),
                ..._groups.map(
                  (g) => DropdownMenuItem(
                    value: g.id,
                    child: Text('${g.name} (${g.membersCount})'),
                  ),
                ),
              ],
              onChanged: (v) {
                _groupFilter = v;
                _load();
              },
            ),
            if (canWrite)
              OutlinedButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.upload_file),
                label: const Text('Импорт XLSX'),
              ),
            if (canGroups)
              OutlinedButton.icon(
                onPressed: _upsertGroup,
                icon: const Icon(Icons.group_add),
                label: const Text('Группа'),
              ),
            if (canWrite || canTerms)
              OutlinedButton.icon(
                onPressed: _showJournal,
                icon: const Icon(Icons.history),
                label: const Text('Журнал'),
              ),
            if (canSuspend)
              OutlinedButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => _bulkSetActive(false),
                child: const Text('Блок выбранных'),
              ),
            if (canSuspend)
              OutlinedButton(
                onPressed: _selected.isEmpty
                    ? null
                    : () => _bulkSetActive(true),
                child: const Text('Восстановить выбранных'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (canTerms)
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final term in _terms)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(
                        '${term.label}${term.isCurrent ? ' · current' : ''}',
                      ),
                      onPressed: () => _prepareTerm(term),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_groups.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final group in _groups)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      label: Text('${group.name} (${group.membersCount})'),
                      selected: _groupFilter == group.id,
                      onSelected: (_) {
                        setState(() {
                          _groupFilter = _groupFilter == group.id
                              ? null
                              : group.id;
                        });
                        _load();
                      },
                      onDeleted: canGroups ? () => _upsertGroup(group) : null,
                      deleteIcon: canGroups
                          ? const Icon(Icons.edit, size: 16)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: Card(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? const Center(child: Text('Студенты не найдены'))
                : ListView(
                    children: [
                      for (final item in _items)
                        CheckboxListTile(
                          value: _selected.contains(item.id),
                          onChanged: (checked) {
                            setState(() {
                              if (checked == true) {
                                _selected.add(item.id);
                              } else {
                                _selected.remove(item.id);
                              }
                            });
                          },
                          title: Text(
                            '${item.surname} ${item.name}'.trim().isEmpty
                                ? item.login
                                : '${item.surname} ${item.name}',
                          ),
                          subtitle: Text(
                            [
                              item.login,
                              item.groupName ?? 'без группы',
                              item.isActive ? 'active' : 'blocked',
                            ].join(' · '),
                          ),
                          secondary: canWrite
                              ? TextButton(
                                  onPressed: () => _edit(item),
                                  child: const Text('Изменить'),
                                )
                              : null,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
