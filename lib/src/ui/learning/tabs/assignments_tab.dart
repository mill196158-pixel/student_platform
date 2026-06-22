import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../state/team_cubit.dart';
import '../models/assignment.dart';
import '../models/team.dart';
import '../assignment_details_screen.dart';
import 'chat/assignments/assignment_form_dialog.dart';

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
              return _AssignmentsEmptyState(
                onCreate: () {
                  _createAssignment(context);
                },
              );
            }

            if (asGrid) {
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: .92,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) => _AssignmentCardTile(
                  a: items[i],
                  onOpen: () => _openDetails(context, items[i].id),
                  onToggle: () =>
                      context.read<TeamCubit>().toggleCompleted(items[i].id),
                ),
              );
            }

            // список
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) => _AssignmentRowTile(
                a: items[i],
                onOpen: () => _openDetails(context, items[i].id),
                onToggle: () =>
                    context.read<TeamCubit>().toggleCompleted(items[i].id),
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

  Future<void> _createAssignment(BuildContext context) async {
    final res = await showAssignmentFormDialog(context);
    if (res == null || !context.mounted) return;

    try {
      await context.read<TeamCubit>().proposeAssignment(
            title: res.$1,
            description: res.$2,
            link: res.$3,
            due: res.$4,
            attachments: res.$5,
          );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось создать задание. Попробуйте ещё раз.'),
        ),
      );
    }
  }
}

class _AssignmentsEmptyState extends StatelessWidget {
  final VoidCallback? onCreate;

  const _AssignmentsEmptyState({
    this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: .55),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.assignment_outlined,
                size: 34,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Заданий пока нет',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Когда староста или студент добавит задание, оно появится здесь.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
                height: 1.25,
              ),
            ),
            if (onCreate != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.assignment_add, size: 18),
                label: const Text('Создать задание'),
              ),
            ],
          ],
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = _assignmentAccent(cs, isDraft: isDraft, isDone: isDone);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onOpen,
        child: Ink(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: accent.withValues(alpha: isDone || isDraft ? .26 : .12),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .055),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AssignmentIconTile(
                icon: _assignmentIcon(isDraft: isDraft, isDone: isDone),
                color: accent,
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
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: cs.onSurface,
                              height: 1.12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (a.description.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        a.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.22,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _StatusPill(
                          text: _statusText(isDraft: isDraft, isDone: isDone),
                          color: accent,
                        ),
                        if ((a.due ?? '').isNotEmpty) ...[
                          const SizedBox(width: 7),
                          _DuePill(due: a.due!, color: cs.tertiary),
                        ],
                        const Spacer(),
                        if (!isDraft)
                          _CompleteActionButton(
                            isDone: isDone,
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
      ),
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accent = _assignmentAccent(cs, isDraft: isDraft, isDone: isDone);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onOpen,
        child: Ink(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: accent.withValues(alpha: isDone || isDraft ? .26 : .12),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .055),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _AssignmentIconTile(
                    icon: _assignmentIcon(isDraft: isDraft, isDone: isDone),
                    color: accent,
                    size: 40,
                  ),
                  const Spacer(),
                  if (!isDraft)
                    _RoundToggleButton(
                      isDone: isDone,
                      color: accent,
                      onPressed: onToggle,
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  a.title,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                    height: 1.12,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _StatusPill(
                    text: _statusText(isDraft: isDraft, isDone: isDone),
                    color: accent,
                    compact: true,
                  ),
                  if ((a.due ?? '').isNotEmpty)
                    _DuePill(due: a.due!, color: cs.tertiary, compact: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _assignmentAccent(
  ColorScheme cs, {
  required bool isDraft,
  required bool isDone,
}) {
  if (isDone) return const Color(0xFF22A06B);
  if (isDraft) return cs.secondary;
  return cs.primary;
}

IconData _assignmentIcon({required bool isDraft, required bool isDone}) {
  if (isDone) return Icons.task_alt_rounded;
  if (isDraft) return Icons.pending_actions_rounded;
  return Icons.assignment_rounded;
}

String _statusText({required bool isDraft, required bool isDone}) {
  if (isDraft) return 'Черновик';
  if (isDone) return 'Готово';
  return 'Активно';
}

class _AssignmentIconTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _AssignmentIconTile({
    required this.icon,
    required this.color,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(icon, color: color, size: size * .55),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String text;
  final Color color;
  final bool compact;

  const _StatusPill({
    required this.text,
    required this.color,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .11),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
      ),
    );
  }
}

class _DuePill extends StatelessWidget {
  final String due;
  final Color color;
  final bool compact;

  const _DuePill({
    required this.due,
    required this.color,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule_rounded, size: compact ? 12 : 13, color: color),
          const SizedBox(width: 4),
          Text(
            'до $due',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompleteActionButton extends StatelessWidget {
  final bool isDone;
  final VoidCallback onPressed;

  const _CompleteActionButton({
    required this.isDone,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = isDone ? const Color(0xFF22A06B) : cs.primary;
    return Material(
      color: color.withValues(alpha: isDone ? .11 : .10),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDone
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                isDone ? 'Готово' : 'Выполнить',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundToggleButton extends StatelessWidget {
  final bool isDone;
  final Color color;
  final VoidCallback onPressed;

  const _RoundToggleButton({
    required this.isDone,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: .11),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            isDone
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: color,
            size: 22,
          ),
        ),
      ),
    );
  }
}
