import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';

class TaskPreviewCard extends StatelessWidget {
  final HomeAssignmentPreview item;
  final VoidCallback onTap;
  final VoidCallback? onDoneTap;
  final bool markingDone;

  const TaskPreviewCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onDoneTap,
    this.markingDone = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final assignment = item.assignment;
    final status = _statusText();
    final statusColor =
        item.isDone ? const Color(0xFF2F9D84) : const Color(0xFFB58B3B);
    final deadlineColor =
        isDark ? const Color(0xFFA78BFA) : const Color(0xFF7C63D8);
    final subjectColor =
        isDark ? const Color(0xFF9DE7D8) : const Color(0xFF2F9D84);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF182331) : Colors.white,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color:
                isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.05),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            _DoneCheckButton(
              done: item.isDone,
              loading: markingDone,
              color: statusColor,
              onTap: onDoneTap,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    assignment.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: titleColor,
                      fontWeight: FontWeight.w900,
                      height: 1.12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _SubjectPill(
                    text: item.teamName.isEmpty ? 'Команда' : item.teamName,
                    color: subjectColor,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _MiniChip(
                        icon: Icons.schedule_rounded,
                        text: _deadlineText(),
                        color: deadlineColor,
                      ),
                      _MiniChip(
                        icon: Icons.flag_outlined,
                        text: status,
                        color: statusColor,
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

  String _deadlineText() {
    final dueAt = item.assignment.dueAt;
    if (dueAt != null) {
      return DateFormat('d MMM', 'ru_RU').format(dueAt);
    }
    final due = item.assignment.due?.trim();
    if (due != null && due.isNotEmpty) return due;
    return 'Без срока';
  }

  String _statusText() {
    if (item.isDone) return 'выполнено';
    switch (item.assignment.status) {
      case 'in_progress':
        return 'в процессе';
      case 'draft':
        return 'не начато';
      case 'published':
      case null:
      case '':
        return 'не начато';
      default:
        return item.assignment.status!;
    }
  }
}

class _DoneCheckButton extends StatelessWidget {
  final bool done;
  final bool loading;
  final Color color;
  final VoidCallback? onTap;

  const _DoneCheckButton({
    required this.done,
    required this.loading,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fillColor = done
        ? const Color(0xFF2F9D84)
        : color.withValues(alpha: isDark ? 0.20 : 0.13);
    final iconColor = done ? Colors.white : color;

    return Tooltip(
      message: done ? 'Задание выполнено' : 'Отметить выполненным',
      child: Semantics(
        button: true,
        label: done ? 'Задание выполнено' : 'Отметить задание выполненным',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: loading ? null : onTap,
            borderRadius: BorderRadius.circular(16),
            splashColor: color.withValues(alpha: 0.12),
            highlightColor: color.withValues(alpha: 0.08),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: fillColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: done
                      ? const Color(0xFF2F9D84)
                      : color.withValues(alpha: isDark ? 0.38 : 0.30),
                  width: 1.4,
                ),
              ),
              child: Center(
                child: loading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: iconColor,
                        ),
                      )
                    : Icon(
                        Icons.check_rounded,
                        color: iconColor,
                        size: 27,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SubjectPill extends StatelessWidget {
  final String text;
  final Color color;

  const _SubjectPill({
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? .16 : .10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.school_outlined, size: 13, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _MiniChip({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
