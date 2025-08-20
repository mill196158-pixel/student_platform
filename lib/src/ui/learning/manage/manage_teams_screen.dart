// lib/src/ui/learning/manage/manage_teams_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../state/learning_cubit.dart';
import '../state/learning_state.dart';
import '../models/team.dart';

class ManageTeamsScreen extends StatefulWidget {
  final String groupCode;
  const ManageTeamsScreen({super.key, required this.groupCode});

  @override
  State<ManageTeamsScreen> createState() => _ManageTeamsScreenState();
}

class _ManageTeamsScreenState extends State<ManageTeamsScreen> {
  String _query = '';

  Future<String?> _askCode(BuildContext context) async {
    final ctrl = TextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Инвайт-код'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Код приглашения',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('Отмена')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Добавить')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Управление командами'),
        actions: [
          IconButton(
            tooltip: 'Добавить по коду',
            icon: const Icon(Icons.add),
            onPressed: () async {
              final code = await _askCode(context);
              if (code != null && code.trim().isNotEmpty) {
                try {
                  await context.read<LearningCubit>().joinByInviteCode(code.trim(), widget.groupCode);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Команда добавлена')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Ошибка: $e')),
                  );
                }
              }
            },
          ),
        ],
      ),
      body: BlocBuilder<LearningCubit, LearningState>(
        builder: (context, state) {
          final allTeams = state.teams;
          final teams = allTeams
              .where((t) =>
                  _query.isEmpty ||
                  t.name.toLowerCase().contains(_query.toLowerCase()) ||
                  t.teacher.toLowerCase().contains(_query.toLowerCase()))
              .toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Поиск',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (s) => setState(() => _query = s),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: teams.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final team = teams[i];
                    return Container(
                      decoration: BoxDecoration(
                        color: theme.cardColor,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Container(
                            height: 36,
                            width: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.grey.shade800,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(team.icon, style: const TextStyle(fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(team.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(team.teacher, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Colors.grey.shade400)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
