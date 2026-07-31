import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import 'teacher_import_service.dart';
import 'teacher_item.dart';
import 'teachers_repository.dart';

class TeachersScreen extends StatefulWidget {
  const TeachersScreen({super.key, required this.session, this.repository});
  final AdminSessionController session;
  final TeachersRepository? repository;
  @override
  State<TeachersScreen> createState() => _TeachersScreenState();
}

class _TeachersScreenState extends State<TeachersScreen> {
  late final TeachersRepository _repository =
      widget.repository ??
      (AdminBackendConfig.isDemoMode
          ? LocalTeachersRepository()
          : SupabaseTeachersRepository());
  List<TeacherItem> _items = const [];
  bool _loading = true;
  String _query = '';
  TeacherStatus? _statusFilter;
  String _sort = 'name_asc';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _items = await _repository.list(
        query: _query,
        status: _statusFilter,
        sort: _sort,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([TeacherItem? item]) async {
    final name = TextEditingController(text: item?.fullName);
    final department = TextEditingController(text: item?.department);
    final position = TextEditingController(text: item?.position);
    final degree = TextEditingController(text: item?.academicDegree);
    final about = TextEditingController(text: item?.aboutText);
    final website = TextEditingController(
      text: item?.contactsPublic['website']?.toString(),
    );
    final publicEmail = TextEditingController(
      text: item?.contactsPublic['public_email']?.toString(),
    );
    final office = TextEditingController(
      text: item?.contactsPublic['office']?.toString(),
    );
    final telegram = TextEditingController(
      text: item?.contactsPublic['telegram']?.toString(),
    );
    var status = item?.status ?? TeacherStatus.draft;
    final result = await showDialog<TeacherItem>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(
            item == null ? 'Новый преподаватель' : 'Карточка преподавателя',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'ФИО'),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  TextField(
                    controller: department,
                    decoration: const InputDecoration(labelText: 'Кафедра'),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  TextField(
                    controller: position,
                    decoration: const InputDecoration(labelText: 'Должность'),
                  ),
                  TextField(
                    controller: degree,
                    decoration: const InputDecoration(
                      labelText: 'Учёная степень',
                    ),
                  ),
                  TextField(
                    controller: about,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'О преподавателе',
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  TextField(
                    controller: website,
                    decoration: const InputDecoration(
                      labelText: 'Публичный сайт',
                    ),
                  ),
                  TextField(
                    controller: publicEmail,
                    decoration: const InputDecoration(
                      labelText: 'Публичный email',
                    ),
                  ),
                  TextField(
                    controller: office,
                    decoration: const InputDecoration(labelText: 'Кабинет'),
                  ),
                  TextField(
                    controller: telegram,
                    decoration: const InputDecoration(
                      labelText: 'Telegram (публичный)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Фотография',
                      helperText:
                          'Загрузка фото отложена до Edge Function teacher-media.',
                    ),
                    child: Text(
                      (item?.photoPath ?? '').isEmpty
                          ? 'Плейсхолдер: фото не загружено'
                          : 'Путь: ${item!.photoPath}',
                    ),
                  ),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Связанные предметы',
                    ),
                    child: Text(
                      (item?.relatedSubjects.isNotEmpty ?? false)
                          ? item!.relatedSubjects.join(', ')
                          : 'Нет связанных предметов (или данные ещё не связаны)',
                    ),
                  ),
                  DropdownButtonFormField<TeacherStatus>(
                    initialValue: status,
                    items: TeacherStatus.values
                        .map(
                          (s) =>
                              DropdownMenuItem(value: s, child: Text(s.name)),
                        )
                        .toList(),
                    onChanged: (v) => setLocal(() => status = v ?? status),
                    decoration: const InputDecoration(labelText: 'Статус'),
                  ),
                  const SizedBox(height: 12),
                  _TeacherPhonePreview(
                    fullName: name.text,
                    department: department.text,
                    about: about.text,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (item != null)
              TextButton(
                onPressed: () async {
                  Navigator.pop(context);
                  await _showVersions(item);
                },
                child: const Text('Версии'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                TeacherItem(
                  id:
                      item?.id ??
                      'new-${DateTime.now().microsecondsSinceEpoch}',
                  fullName: name.text.trim(),
                  department: department.text.trim(),
                  position: position.text.trim(),
                  academicDegree: degree.text.trim(),
                  aboutText: about.text.trim(),
                  status: status,
                  photoPath: item?.photoPath,
                  relatedSubjects: item?.relatedSubjects ?? const [],
                  contactsPublic: {
                    if (website.text.trim().isNotEmpty)
                      'website': website.text.trim(),
                    if (publicEmail.text.trim().isNotEmpty)
                      'public_email': publicEmail.text.trim(),
                    if (office.text.trim().isNotEmpty)
                      'office': office.text.trim(),
                    if (telegram.text.trim().isNotEmpty)
                      'telegram': telegram.text.trim(),
                  },
                ),
              ),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result != null) {
      await _repository.save(result);
      await _load();
    }
  }

  Future<void> _showVersions(TeacherItem item) async {
    final versions = await _repository.listVersions(item.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Версии · ${item.fullName}'),
        content: SizedBox(
          width: 480,
          height: 320,
          child: versions.isEmpty
              ? const Center(child: Text('Версий пока нет'))
              : ListView(
                  children: [
                    for (final version in versions)
                      ListTile(
                        title: Text('v${version['version_number']}'),
                        subtitle: Text(version['created_at']?.toString() ?? ''),
                        trailing: TextButton(
                          onPressed: () async {
                            final number =
                                int.tryParse('${version['version_number']}') ??
                                0;
                            await _repository.restoreVersion(item.id, number);
                            if (context.mounted) Navigator.pop(context);
                            await _load();
                          },
                          child: const Text('Восстановить'),
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

  Future<void> _showJournal() async {
    final batches = await _repository.listImportBatches();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Журнал импорта'),
        content: SizedBox(
          width: 560,
          height: 380,
          child: batches.isEmpty
              ? const Center(child: Text('Импортов пока нет'))
              : ListView(
                  children: [
                    for (final batch in batches)
                      ListTile(
                        title: Text(
                          '${batch['status'] ?? ''} · ${batch['id'] ?? ''}',
                        ),
                        subtitle: Text(
                          '${batch['summary'] ?? {}} · ${batch['created_at'] ?? ''}',
                        ),
                        trailing: TextButton(
                          onPressed: () async {
                            final rows = await _repository.listImportRows(
                              '${batch['id']}',
                            );
                            if (!context.mounted) return;
                            await showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text('Строки · ${batch['id']}'),
                                content: SizedBox(
                                  width: 560,
                                  height: 360,
                                  child: ListView(
                                    children: [
                                      for (final row in rows)
                                        ListTile(
                                          dense: true,
                                          title: Text(
                                            '#${row['row_number']} · ${row['classification']} · ${row['payload']?['full_name'] ?? ''}',
                                          ),
                                          subtitle: Text(
                                            [
                                              if (row['error_text'] != null)
                                                row['error_text'],
                                              if (row['matched_teacher_id'] !=
                                                  null)
                                                'match=${row['matched_teacher_id']}',
                                            ].join(' · '),
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

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.first.bytes;
    final fileName = picked.files.first.name;
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось прочитать файл')),
      );
      return;
    }

    try {
      final workbook = TeacherImportService().readWorkbook(bytes);
      if (!mounted) return;
      var sheet = workbook.sheets.first;
      if (workbook.sheets.length > 1) {
        final selected = await showDialog<TeacherImportSheet>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Выберите лист'),
            children: [
              for (final candidate in workbook.sheets)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, candidate),
                  child: Text(
                    '${candidate.name} (${candidate.rows.length} строк)',
                  ),
                ),
            ],
          ),
        );
        if (selected == null) return;
        sheet = selected;
      }

      var mapping = suggestHeaderMapping(sheet.headers);
      if (!mounted) return;
      final confirmedMapping = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) => _MappingDialog(
          headers: sheet.headers,
          initial: mapping,
          fileName: fileName,
        ),
      );
      if (confirmedMapping == null) return;
      mapping = confirmedMapping;

      // Keep empty-FIO rows so dry-run/journal can show validation errors.
      final rows = <Map<String, dynamic>>[
        for (final raw in sheet.rows) mapImportRow(raw, mapping),
      ];

      final dry = await _repository.importDryRun(rows);
      if (!mounted) return;
      final apply = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Dry-run импорта преподавателей'),
          content: SizedBox(
            width: 560,
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Файл: $fileName'),
                Text('Строк к проверке: ${dry['rows'] ?? rows.length}'),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: [
                      for (final item in (dry['items'] as List? ?? const []))
                        ListTile(
                          dense: true,
                          title: Text(
                            '${item['classification']} · ${item['payload']?['full_name'] ?? '(пустое ФИО)'}',
                          ),
                          subtitle: Text(
                            item['error_text']?.toString() ??
                                item['matched_teacher_id']?.toString() ??
                                '',
                          ),
                        ),
                    ],
                  ),
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
                ? 'Повтор: импорт уже был применён'
                : 'Импорт: +${result['created'] ?? 0} / ~${result['updated'] ?? 0}',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Импорт не выполнен: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canWrite =
        widget.session.isLocalPrototype ||
        widget.session.capabilities.canWriteTeachers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Преподаватели',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Справочник преподавателей. Изменения выполняются только через защищённые RPC.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 360,
              child: TextField(
                onChanged: (value) {
                  _query = value;
                  _load();
                },
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'ФИО или кафедра',
                ),
              ),
            ),
            DropdownButton<TeacherStatus?>(
              value: _statusFilter,
              hint: const Text('Все статусы'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Все')),
                ...TeacherStatus.values.map(
                  (s) => DropdownMenuItem(value: s, child: Text(s.name)),
                ),
              ],
              onChanged: (value) {
                _statusFilter = value;
                _load();
              },
            ),
            DropdownButton<String>(
              value: _sort,
              items: const [
                DropdownMenuItem(value: 'name_asc', child: Text('А→Я')),
                DropdownMenuItem(value: 'name_desc', child: Text('Я→А')),
                DropdownMenuItem(
                  value: 'updated_desc',
                  child: Text('Сначала обновлённые'),
                ),
              ],
              onChanged: (value) {
                _sort = value ?? 'name_asc';
                _load();
              },
            ),
            if (canWrite)
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('Добавить'),
              ),
            if (canWrite)
              OutlinedButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.upload_file),
                label: const Text('Импорт XLSX'),
              ),
            if (canWrite)
              OutlinedButton.icon(
                onPressed: _showJournal,
                icon: const Icon(Icons.history),
                label: const Text('Журнал'),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Expanded(
          child: Card(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? const Center(child: Text('Преподаватели не найдены'))
                : ListView(
                    children: _items
                        .map(
                          (item) => ListTile(
                            leading: CircleAvatar(
                              child: Text(
                                item.fullName.isEmpty ? '?' : item.fullName[0],
                              ),
                            ),
                            title: Text(item.fullName),
                            subtitle: Text(
                              [
                                item.department ?? 'Кафедра не указана',
                                if ((item.position ?? '').isNotEmpty)
                                  item.position!,
                                item.status.name,
                                if (item.relatedSubjects.isNotEmpty)
                                  item.relatedSubjects.take(2).join(', '),
                                if (item.photoPlaceholder) 'без фото',
                              ].join(' · '),
                            ),
                            trailing: canWrite
                                ? TextButton(
                                    onPressed: () => _edit(item),
                                    child: const Text('Редактировать'),
                                  )
                                : null,
                          ),
                        )
                        .toList(),
                  ),
          ),
        ),
      ],
    );
  }
}

class _MappingDialog extends StatefulWidget {
  const _MappingDialog({
    required this.headers,
    required this.initial,
    required this.fileName,
  });

  final List<String> headers;
  final Map<String, String> initial;
  final String fileName;

  @override
  State<_MappingDialog> createState() => _MappingDialogState();
}

class _MappingDialogState extends State<_MappingDialog> {
  static const _fields = <String, String>{
    'teacher_id': 'ID преподавателя',
    'full_name': 'ФИО',
    'department': 'Кафедра',
    'position': 'Должность',
    'academic_degree': 'Учёная степень',
    'about_text': 'Описание',
    'public_email': 'Публичный email',
    'website': 'Сайт',
    'office': 'Кабинет',
    'telegram': 'Telegram',
  };

  late Map<String, String?> _mapping;

  @override
  void initState() {
    super.initState();
    _mapping = {for (final key in _fields.keys) key: widget.initial[key]};
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Сопоставление колонок · ${widget.fileName}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            children: [
              for (final entry in _fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<String?>(
                    initialValue: _mapping[entry.key],
                    decoration: InputDecoration(labelText: entry.value),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('— не использовать —'),
                      ),
                      ...widget.headers.map(
                        (header) => DropdownMenuItem(
                          value: header,
                          child: Text(header),
                        ),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _mapping[entry.key] = value),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final result = <String, String>{};
            _mapping.forEach((field, header) {
              if (header != null && header.isNotEmpty) result[field] = header;
            });
            if (!result.containsKey('full_name')) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Нужно сопоставить колонку ФИО')),
              );
              return;
            }
            Navigator.pop(context, result);
          },
          child: const Text('Продолжить к dry-run'),
        ),
      ],
    );
  }
}

class _TeacherPhonePreview extends StatelessWidget {
  const _TeacherPhonePreview({
    required this.fullName,
    required this.department,
    required this.about,
  });

  final String fullName;
  final String department;
  final String about;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black12),
        color: const Color(0xFFF7F8FB),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Превью мобильной карточки',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          Text(
            fullName.trim().isEmpty ? 'ФИО преподавателя' : fullName.trim(),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            department.trim().isEmpty ? 'Кафедра' : department.trim(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (about.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(about.trim()),
          ],
        ],
      ),
    );
  }
}
