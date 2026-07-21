import 'package:flutter/material.dart';

import '../../../shared/widgets/publication_status_badge.dart';

class TeachersScreen extends StatefulWidget {
  const TeachersScreen({super.key});

  @override
  State<TeachersScreen> createState() => _TeachersScreenState();
}

class _TeachersScreenState extends State<TeachersScreen> {
  static const _teachers = [
    _TeacherRow(
      'Анна Викторовна Соколова',
      'Информационные системы',
      3,
      'Черновик',
    ),
    _TeacherRow(
      'Михаил Сергеевич Лебедев',
      'Прикладная математика',
      2,
      'Опубликован',
    ),
    _TeacherRow(
      'Ольга Андреевна Морозова',
      'Информационная безопасность',
      4,
      'Опубликован',
    ),
    _TeacherRow(
      'Илья Павлович Волков',
      'Экономика и управление',
      1,
      'Черновик',
    ),
  ];

  String _query = '';
  String _status = 'Все';

  List<_TeacherRow> get _filtered {
    final normalized = _query.trim().toLowerCase();
    return _teachers.where((teacher) {
      final matchesQuery =
          teacher.name.toLowerCase().contains(normalized) ||
          teacher.department.toLowerCase().contains(normalized);
      final matchesStatus = _status == 'Все' || teacher.status == _status;
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
          'Преподаватели',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Будущий справочник преподавателей и связей с предметами. Сейчас показаны mock-данные.',
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
                  hintText: 'Найти преподавателя или кафедру',
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
                          DataColumn(label: Text('ФИО')),
                          DataColumn(label: Text('Кафедра')),
                          DataColumn(label: Text('Предметов')),
                          DataColumn(label: Text('Статус')),
                          DataColumn(label: Text('Действие')),
                        ],
                        rows: [
                          for (final teacher in rows)
                            DataRow(
                              cells: [
                                DataCell(
                                  SizedBox(
                                    width: 270,
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.primaryContainer,
                                          child: Text(_initials(teacher.name)),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            teacher.name,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 260,
                                    child: Text(teacher.department),
                                  ),
                                ),
                                DataCell(Text('${teacher.subjectCount}')),
                                DataCell(
                                  PublicationStatusBadge(
                                    status: teacher.status,
                                  ),
                                ),
                                DataCell(
                                  TextButton(
                                    onPressed: () =>
                                        _showMockEdit(teacher.name),
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

  String _initials(String name) {
    final parts = name.split(' ');
    return parts.take(2).map((part) => part[0]).join();
  }

  void _showMockEdit(String name) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Карточка «$name» появится на этапе 12.5')),
    );
  }
}

class _TeacherRow {
  const _TeacherRow(this.name, this.department, this.subjectCount, this.status);

  final String name;
  final String department;
  final int subjectCount;
  final String status;
}
