import 'package:student_ui/student_ui.dart' show ProductTheme, ProductLoadingIndicator;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'subject_item.dart';

typedef ScheduleIssuesLoader = Future<List<Map<String, dynamic>>> Function();
typedef ScheduleSubjectBinder =
    Future<Map<String, dynamic>> Function(
      String groupId,
      String raw,
      String subjectId,
    );

class ScheduleSubjectReviewScreen extends StatefulWidget {
  const ScheduleSubjectReviewScreen({
    super.key,
    required this.subjects,
    this.loadIssues,
    this.bindSubject,
  });
  final List<SubjectItem> subjects;
  final ScheduleIssuesLoader? loadIssues;
  final ScheduleSubjectBinder? bindSubject;
  @override
  State<ScheduleSubjectReviewScreen> createState() => _ReviewState();
}

class _ReviewState extends State<ScheduleSubjectReviewScreen> {
  List<Map<String, dynamic>> _issues = [];
  bool _loading = true, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = widget.loadIssues != null
          ? await widget.loadIssues!()
          : (await Supabase.instance.client.rpc(
                      'admin_list_unlinked_schedule_subjects',
                    )
                    as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
      if (mounted) {
        setState(() {
          _issues = rows;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось загрузить названия. Повторите попытку.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _bind(Map<String, dynamic> row) async {
    if (_saving) return;
    String? selected;
    final id = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text('Сопоставить «${row['raw_subject']}»'),
          content: SizedBox(
            width: 480,
            child: DropdownButtonFormField<String>(
              borderRadius: ProductTheme.selectionMenuRadius,
              elevation: ProductTheme.selectionMenuElevation,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              isExpanded: true,
              initialValue: selected,
              decoration: const InputDecoration(
                labelText: 'Предмет из справочника',
              ),
              items: [
                for (final s in widget.subjects.where(
                  (s) => s.status != SubjectStatus.archived,
                ))
                  DropdownMenuItem(
                    value: s.id,
                    child: Text(
                      s.canonicalName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => change(() => selected = value),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(context, selected),
              child: const Text('Сопоставить'),
            ),
          ],
        ),
      ),
    );
    if (id == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final group = '${row['group_id']}';
      final raw = '${row['raw_subject']}';
      final result = widget.bindSubject != null
          ? await widget.bindSubject!(group, raw, id)
          : Map<String, dynamic>.from(
              await Supabase.instance.client.rpc(
                    'admin_bind_schedule_subject',
                    params: {
                      'p_group_id': group,
                      'p_raw_subject': raw,
                      'p_subject_id': id,
                    },
                  )
                  as Map,
            );
      if (!mounted) return;
      final batches = result['subject_sync'] as List? ?? [];
      final pending = batches.fold<int>(
        0,
        (n, b) => n + ((b as Map)['pending'] as num? ?? 0).toInt(),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            pending == 0
                ? 'Сопоставление сохранено'
                : 'Название сохранено. Осталось несопоставленных занятий: $pending. Проверьте период и группу.',
          ),
        ),
      );
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось сопоставить. Проверьте права и не связано ли название с другим предметом.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Предметы из расписания')),
    body: _loading
        ? const Center(child: ProductLoadingIndicator())
        : Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Точные названия и алиасы связываются автоматически при импорте. Здесь можно проверить остальные. Учебный план не обязателен.',
                ),
              ),
              if (_error != null)
                ListTile(
                  title: Text(_error!),
                  trailing: TextButton(
                    onPressed: _load,
                    child: const Text('Повторить'),
                  ),
                ),
              if (_saving) const LinearProgressIndicator(),
              Expanded(
                child: _issues.isEmpty && _error == null
                    ? const Center(child: Text('Все названия сопоставлены'))
                    : ListView(
                        children: [
                          for (final row in _issues)
                            ListTile(
                              title: Text('${row['raw_subject']}'),
                              subtitle: Text(
                                '${row['group_name']} · занятий: ${row['lesson_count']} · ${row['first_date']} — ${row['last_date']}',
                              ),
                              trailing: TextButton(
                                onPressed: _saving ? null : () => _bind(row),
                                child: const Text('Сопоставить'),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
  );
}
