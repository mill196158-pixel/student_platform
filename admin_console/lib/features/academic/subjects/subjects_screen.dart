import 'package:admin_import_mapping/admin_import_mapping.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/auth/admin_backend_config.dart';
import '../../../core/auth/admin_session_controller.dart';
import '../teachers/teacher_import_service.dart';
import '../teachers/teachers_repository.dart';
import 'subject_card_editor_screen.dart';
import 'subject_item.dart';
import 'subjects_repository.dart';

// parseUsefulLinks comes from admin_import_mapping.

class SubjectsScreen extends StatefulWidget {
  const SubjectsScreen({super.key, required this.session, this.repository});
  final AdminSessionController session;
  final SubjectsRepository? repository;
  @override
  State<SubjectsScreen> createState() => _SubjectsScreenState();
}

class _SubjectsScreenState extends State<SubjectsScreen> {
  late final SubjectsRepository _repository =
      widget.repository ??
      (AdminBackendConfig.isDemoMode
          ? LocalSubjectsRepository()
          : SupabaseSubjectsRepository());
  List<SubjectItem> _items = const [];
  bool _loading = true;
  String _query = '';
  SubjectStatus? _statusFilter;
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

  Future<void> _edit([SubjectItem? item]) async {
    final saved = await Navigator.of(context).push<SubjectItem>(
      MaterialPageRoute(
        builder: (_) => SubjectCardEditorScreen(
          repository: _repository,
          teachersRepository: AdminBackendConfig.isDemoMode
              ? LocalTeachersRepository()
              : SupabaseTeachersRepository(),
          session: widget.session,
          item: item,
        ),
      ),
    );
    if (saved != null) await _load();
  }

  Future<void> _showVersions(SubjectItem item) async {
    final versions = await _repository.listVersions(item.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Версии · ${item.canonicalName}'),
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
                        trailing: TextButton(
                          onPressed: () async {
                            final number =
                                int.tryParse('${version['version_number']}') ??
                                0;
                            await _repository.restoreVersion(
                              item.id,
                              number,
                              expectedCatalogRowVersion:
                                  item.catalogRowVersion,
                              expectedProfileRowVersion:
                                  item.profileRowVersion,
                            );
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
        title: const Text('Журнал импорта предметов'),
        content: SizedBox(
          width: 560,
          height: 360,
          child: batches.isEmpty
              ? const Center(child: Text('Импортов пока нет'))
              : ListView(
                  children: [
                    for (final batch in batches)
                      ListTile(
                        title: Text('${batch['status']} · ${batch['id']}'),
                        subtitle: Text('${batch['summary']}'),
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
                                  height: 320,
                                  child: ListView(
                                    children: [
                                      for (final row in rows)
                                        ListTile(
                                          dense: true,
                                          title: Text(
                                            '#${row['row_number']} · ${row['classification']} · ${row['payload']?['canonical_name'] ?? ''}',
                                          ),
                                          subtitle: Text(
                                            row['error_text']?.toString() ??
                                                row['matched_subject_id']
                                                    ?.toString() ??
                                                '',
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
      var mapping = suggestSubjectHeaderMapping(sheet.headers);
      if (!mounted) return;
      final confirmed = await showDialog<Map<String, String>>(
        context: context,
        builder: (context) => _SubjectMappingDialog(
          headers: sheet.headers,
          initial: mapping,
          fileName: fileName,
        ),
      );
      if (confirmed == null) return;
      mapping = confirmed;
      final rows = [for (final raw in sheet.rows) mapImportRow(raw, mapping)];
      final dry = await _repository.importDryRun(rows);
      if (!mounted) return;
      final apply = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Dry-run импорта предметов'),
          content: SizedBox(
            width: 560,
            height: 360,
            child: ListView(
              children: [
                Text('Файл: $fileName · строк: ${dry['rows'] ?? rows.length}'),
                for (final item in (dry['items'] as List? ?? const []))
                  ListTile(
                    dense: true,
                    title: Text(
                      '${item['classification']} · ${item['payload']?['canonical_name'] ?? '(пусто)'}',
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
        widget.session.capabilities.canWriteSubjects;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Предметы',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Общие сведения для студентов. Подробности — внутри карточки; список остаётся коротким.',
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
                  hintText: 'Название или кафедра',
                ),
              ),
            ),
            DropdownButton<SubjectStatus?>(
              value: _statusFilter,
              hint: const Text('Все статусы'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Все')),
                ...SubjectStatus.values.map(
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
                ? const Center(child: Text('Предметы не найдены'))
                : ListView(
                    children: [
                      for (final item in _items)
                        ListTile(
                          title: Text(item.canonicalName),
                          subtitle: Text(
                            [
                              item.department ?? 'Кафедра не указана',
                              if ((item.controlForm ?? '').isNotEmpty)
                                item.controlForm!,
                              item.status.name,
                            ].join(' · '),
                          ),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              TextButton(
                                onPressed: () => _showVersions(item),
                                child: const Text('Версии'),
                              ),
                              if (canWrite)
                                TextButton(
                                  onPressed: () => _edit(item),
                                  child: const Text('Открыть'),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _SubjectMappingDialog extends StatefulWidget {
  const _SubjectMappingDialog({
    required this.headers,
    required this.initial,
    required this.fileName,
  });
  final List<String> headers;
  final Map<String, String> initial;
  final String fileName;
  @override
  State<_SubjectMappingDialog> createState() => _SubjectMappingDialogState();
}

class _SubjectMappingDialogState extends State<_SubjectMappingDialog> {
  static const _fields = <String, String>{
    'subject_id': 'ID предмета',
    'canonical_name': 'Название',
    'department': 'Кафедра',
    'control_form': 'Форма контроля',
    'difficulty_label': 'Сложность',
    'description': 'Описание',
    'short_description': 'Краткое описание',
    'learning_outcomes': 'Чему научится',
    'requirements': 'Требования',
    'what_to_expect': 'Чего ожидать',
    'how_to_pass': 'Как сдать',
    'useful_materials_note': 'Материалы',
    'useful_links': 'Полезные ссылки',
    'common_pitfalls': 'Типичные ошибки',
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
            if (!result.containsKey('canonical_name')) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Нужно сопоставить колонку названия'),
                ),
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

