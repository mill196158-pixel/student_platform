import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../state/team_cubit.dart';
import '../../models/assignment.dart';
import '../../assignment_details_screen.dart';
import 'assignment_card.dart';

enum _Filter { all, active, overdue, draft }

class AssignmentsTab extends StatefulWidget {
  final Object? team; // совместимость с вызовом AssignmentsTab(team: state.team)
  const AssignmentsTab({super.key, this.team});

  @override
  State<AssignmentsTab> createState() => _AssignmentsTabState();
}

class _AssignmentsTabState extends State<AssignmentsTab> {
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final st = context.watch<TeamCubit>().state;
    final items = _apply(st);

    return Column(
      children: [
        const SizedBox(height: 8),
        _Filters(
          value: _filter,
          hasDraft: st.hasPending,
          onChanged: (v) => setState(() => _filter = v),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final a = items[i];
              final isDraft = st.pending?.id == a.id;
              return AssignmentCard(
                assignment: a,
                isDraft: isDraft,
                canPublish: isDraft && st.isStarosta,
                onOpen: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BlocProvider.value(
                      value: context.read<TeamCubit>(),
                      child: AssignmentDetailsScreen(assignmentId: a.id),
                    ),
                  ),
                ),
                onPublish: () => context.read<TeamCubit>().publishPendingManually(),
                onVote: () => context.read<TeamCubit>().voteForPending(),
                onEdit: () async {
                  final res = await _editAssignmentDialog(context, a);
                  if (res == null) return;
                  await context.read<TeamCubit>().updateAssignment(
                        a.id,
                        title: res.$1,
                        description: res.$2,
                        link: res.$3,
                        due: res.$4,
                        attachments: res.$5,
                      );
                },
                onDelete: () => context.read<TeamCubit>().removeAssignment(a.id),
              );
            },
          ),
        ),
      ],
    );
  }

  List<Assignment> _apply(TeamState st) {
    final now = DateTime.now();
    bool overdue(Assignment a) {
      if (a.due == null) return false;
      final parts = a.due!.split('.');
      if (parts.length != 2) return false;
      final d = int.tryParse(parts[0]) ?? 1;
      final m = int.tryParse(parts[1]) ?? 1;
      final due = DateTime(now.year, m, d);
      return due.isBefore(DateTime(now.year, now.month, now.day));
    }

    Iterable<Assignment> base = st.assignments;
    switch (_filter) {
      case _Filter.all:
        break;
      case _Filter.active:
        base = base.where((a) => !overdue(a));
        break;
      case _Filter.overdue:
        base = base.where(overdue);
        break;
      case _Filter.draft:
        final p = st.pending;
        base = p == null ? const Iterable.empty() : [p];
        break;
    }
    return base.toList();
  }

  Future<(String, String, String?, String?, List<Map<String, String>>)?> _editAssignmentDialog(
      BuildContext context, Assignment a) async {
    final title = TextEditingController(text: a.title);
    final desc  = TextEditingController(text: a.description);
    final link  = TextEditingController(text: a.link ?? '');
    final due   = TextEditingController(text: a.due ?? '');
    final files = [...a.attachments];

    return showDialog<(String, String, String?, String?, List<Map<String, String>>)>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Center(child: Text('Редактировать задание', style: TextStyle(fontWeight: FontWeight.w700))),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Название')),
                const SizedBox(height: 8),
                TextField(controller: desc, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Что сделать')),
                const SizedBox(height: 8),
                TextField(controller: link, decoration: const InputDecoration(labelText: 'Ссылка (опц.)')),
                const SizedBox(height: 8),
                TextField(controller: due, decoration: const InputDecoration(labelText: 'Срок (напр. 20.09)')),
                const SizedBox(height: 8),
                for (final f in files)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(f['name'] ?? ''),
                    subtitle: Text(f['path'] ?? ''),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty || desc.text.trim().isEmpty) return;
                Navigator.pop(context, (
                  title.text.trim(),
                  desc.text.trim(),
                  link.text.trim().isEmpty ? null : link.text.trim(),
                  due.text.trim().isEmpty ? null : due.text.trim(),
                  files
                ));
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  final _Filter value;
  final bool hasDraft;
  final ValueChanged<_Filter> onChanged;
  const _Filters({required this.value, required this.hasDraft, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget chip(_Filter f, String label) {
      final sel = value == f;
      return ChoiceChip(
        label: Text(label),
        selected: sel,
        onSelected: (_) => onChanged(f),
        selectedColor: cs.primary.withOpacity(.12),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          chip(_Filter.all, 'Все'),
          const SizedBox(width: 8),
          chip(_Filter.active, 'Активные'),
          const SizedBox(width: 8),
          chip(_Filter.overdue, 'Просроченные'),
          if (hasDraft) ...[
            const SizedBox(width: 8),
            chip(_Filter.draft, 'Черновик'),
          ],
        ],
      ),
    );
  }
}
