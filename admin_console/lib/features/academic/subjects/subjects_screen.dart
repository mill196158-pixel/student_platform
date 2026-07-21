import 'package:flutter/material.dart';

import '../../../shared/widgets/publication_status_badge.dart';

class SubjectsScreen extends StatefulWidget {
  const SubjectsScreen({super.key});

  @override
  State<SubjectsScreen> createState() => _SubjectsScreenState();
}

class _SubjectsScreenState extends State<SubjectsScreen> {
  static const _subjects = [
    _SubjectRow(
      'Архитектура информационных систем',
      82,
      'Опубликован',
      'Сегодня',
    ),
    _SubjectRow('Базы данных', 64, 'Черновик', 'Вчера'),
    _SubjectRow('Информационная безопасность', 100, 'Опубликован', '18 июля'),
    _SubjectRow('Математическая статистика', 38, 'Черновик', '15 июля'),
    _SubjectRow('Управление IT-проектами', 76, 'Опубликован', '12 июля'),
  ];

  String _query = '';
  String _status = 'Все';

  List<_SubjectRow> get _filtered {
    final normalized = _query.trim().toLowerCase();
    return _subjects.where((subject) {
      final matchesQuery = subject.name.toLowerCase().contains(normalized);
      final matchesStatus = _status == 'Все' || subject.status == _status;
      return matchesQuery && matchesStatus;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _filtered;
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
          'Общие сведения для студентов. Сейчас показаны mock-данные.',
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            SizedBox(
              width: 360,
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Найти предмет',
                ),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(labelText: 'Статус'),
                items: const [
                  DropdownMenuItem(value: 'Все', child: Text('Все')),
                  DropdownMenuItem(
                    value: 'Опубликован',
                    child: Text('Опубликован'),
                  ),
                  DropdownMenuItem(value: 'Черновик', child: Text('Черновик')),
                ],
                onChanged: (value) => setState(() => _status = value ?? 'Все'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Expanded(
          child: Card(
            child: rows.isEmpty
                ? const Center(child: Text('Ничего не найдено'))
                : SingleChildScrollView(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Название')),
                          DataColumn(label: Text('Заполненность')),
                          DataColumn(label: Text('Статус')),
                          DataColumn(label: Text('Изменён')),
                          DataColumn(label: Text('Действие')),
                        ],
                        rows: [
                          for (final subject in rows)
                            DataRow(
                              cells: [
                                DataCell(
                                  SizedBox(
                                    width: 310,
                                    child: Text(
                                      subject.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 150,
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: LinearProgressIndicator(
                                            value: subject.completeness / 100,
                                            minHeight: 7,
                                            borderRadius: BorderRadius.circular(
                                              99,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Text('${subject.completeness}%'),
                                      ],
                                    ),
                                  ),
                                ),
                                DataCell(
                                  PublicationStatusBadge(
                                    status: subject.status,
                                  ),
                                ),
                                DataCell(Text(subject.changed)),
                                DataCell(
                                  TextButton(
                                    onPressed: () =>
                                        _showMockEdit(subject.name),
                                    child: const Text('Редактировать'),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  void _showMockEdit(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Форма «$name» появится на этапе 12.4')),
    );
  }
}

class _SubjectRow {
  const _SubjectRow(this.name, this.completeness, this.status, this.changed);

  final String name;
  final int completeness;
  final String status;
  final String changed;
}
