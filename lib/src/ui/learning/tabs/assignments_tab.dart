import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../state/team_cubit.dart';
import '../models/assignment.dart';
import '../models/team.dart';
import '../assignment_details_screen.dart';

// общий notifier
import 'assignments/view_mode.dart';

class AssignmentsTab extends StatelessWidget {
  final Team team;
  const AssignmentsTab({super.key, required this.team});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AssignmentsViewMode.grid,
      builder: (context, asGrid, _) {
        return BlocBuilder<TeamCubit, TeamState>(
          builder: (context, state) {
            final items = [...state.assignments];

            int rank(Assignment x) {
              if (!x.published) return 0;
              if (!x.completedByMe) return 1;
              return 2;
            }

            items.sort((a, b) {
              final r = rank(a) - rank(b);
              if (r != 0) return r;
              return a.createdAt.compareTo(b.createdAt);
            });

            if (items.isEmpty) {
              return const Center(child: Text('Пока нет заданий'));
            }

            if (asGrid) {
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.05,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) => _AssignmentCardTile(
                  a: items[i],
                  onOpen: () => _openDetails(context, items[i].id),
                  onToggle: () => context.read<TeamCubit>().toggleCompleted(items[i].id),
                ),
              );
            }

            // список
            return ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _AssignmentRowTile(
                a: items[i],
                onOpen: () => _openDetails(context, items[i].id),
                onToggle: () => context.read<TeamCubit>().toggleCompleted(items[i].id),
              ),
            );
          },
        );
      },
    );
  }

  void _openDetails(BuildContext context, String id) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: context.read<TeamCubit>(),
          child: AssignmentDetailsScreen(assignmentId: id),
        ),
      ),
    );
  }
}

class _AssignmentRowTile extends StatelessWidget {
  final Assignment a;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  const _AssignmentRowTile({
    required this.a,
    required this.onOpen,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDraft = !a.published;
    final isDone = a.completedByMe;
    final cs = Theme.of(context).colorScheme;

    Color cardColor() {
      if (isDraft) return cs.surfaceContainerHighest.withOpacity(.5);
      if (isDone) return Colors.green.withOpacity(.10);
      return cs.surface;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onOpen,
      child: Container(
        decoration: BoxDecoration(
          color: cardColor(),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDone ? Colors.green : cs.outlineVariant.withOpacity(.6),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isDraft ? Icons.pending_outlined : Icons.assignment_outlined,
              color: isDone ? Colors.green : cs.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          a.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if ((a.due ?? '').isNotEmpty)
                        Text('до ${a.due!}',
                            style: const TextStyle(fontSize: 13, color: Colors.black54)),
                    ],
                  ),
                  if (a.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      a.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: Colors.black87),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _statusChip(context, isDraft, isDone),
                      const Spacer(),
                      if (!isDraft)
                        OutlinedButton.icon(
                          icon: Icon(isDone
                              ? Icons.check_box
                              : Icons.check_box_outline_blank),
                          label: Text(isDone ? 'Не выполнено' : 'Выполнено'),
                          onPressed: onToggle,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(BuildContext context, bool isDraft, bool isDone) {
    final cs = Theme.of(context).colorScheme;
    if (isDraft) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text('Черновик', style: TextStyle(fontSize: 12)),
      );
    }
    if (isDone) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.green),
        ),
        child: const Text('Выполнено', style: TextStyle(fontSize: 12, color: Colors.green)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text('Опубликовано', style: TextStyle(fontSize: 12)),
    );
  }
}

class _AssignmentCardTile extends StatelessWidget {
  final Assignment a;
  final VoidCallback onOpen;
  final VoidCallback onToggle;

  const _AssignmentCardTile({
    required this.a,
    required this.onOpen,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final isDraft = !a.published;
    final isDone = a.completedByMe;
    final cs = Theme.of(context).colorScheme;

    Color cardColor() {
      if (isDraft) return cs.surfaceContainerHighest.withOpacity(.5);
      if (isDone) return Colors.green.withOpacity(.10);
      return cs.surface;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onOpen,
      child: Container(
        decoration: BoxDecoration(
          color: cardColor(),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDone ? Colors.green : cs.outlineVariant.withOpacity(.6),
            width: 1,
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isDraft ? Icons.pending_outlined : Icons.assignment_outlined,
                  color: isDone ? Colors.green : cs.primary,
                ),
                const Spacer(),
                if (!isDraft)
                  IconButton(
                    tooltip: isDone ? 'Отметить как не выполнено' : 'Отметить как выполнено',
                    icon: Icon(isDone ? Icons.check_box : Icons.check_box_outline_blank, size: 22),
                    onPressed: onToggle,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Text(
                a.title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.black87,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _statusMini(isDraft, isDone, cs),
                const Spacer(),
                if ((a.due ?? '').isNotEmpty)
                  Text('до ${a.due!}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusMini(bool isDraft, bool isDone, ColorScheme cs) {
    Color bg;
    String text;
    Color? border;
    if (isDraft) {
      bg = cs.secondaryContainer; text = 'Черновик';
    } else if (isDone) {
      bg = Colors.green.withOpacity(.12); text = 'Выполнено'; border = Colors.green;
    } else {
      bg = cs.primaryContainer; text = 'Опубликовано';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border != null ? Border.all(color: border) : null,
      ),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );
  }
}
