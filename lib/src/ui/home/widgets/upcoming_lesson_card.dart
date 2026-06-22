import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/schedule/models/lesson.dart';

class UpcomingLessonCard extends StatelessWidget {
  final Lesson lesson;
  final VoidCallback onTap;

  const UpcomingLessonCard({
    super.key,
    required this.lesson,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final (label, accent) = _badgeFor(lesson);

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 68,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: isDark ? 0.16 : 0.10),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Text(
                    _time(lesson.start),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${lesson.pairNum}-я',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accent.withValues(alpha: 0.76),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          lesson.subject,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            height: 1.12,
                          ),
                        ),
                      ),
                      if (label.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _LessonChip(label: label, color: accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 9),
                  if ((lesson.teacher ?? '').isNotEmpty)
                    _MetaLine(
                        icon: Icons.person_outline, text: lesson.teacher!),
                  if ((lesson.room ?? '').isNotEmpty) ...[
                    const SizedBox(height: 5),
                    _MetaLine(
                        icon: Icons.location_on_outlined, text: lesson.room!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _badgeFor(Lesson lesson) {
    switch (lesson.type) {
      case LessonType.lecture:
        return ('Лекция', const Color(0xFFB86B6B));
      case LessonType.practice:
        return ('Практика', const Color(0xFF7C63D8));
      case LessonType.lab:
        return ('Лаб.', const Color(0xFF2F9D84));
      case LessonType.other:
        return ('', const Color(0xFF7B8794));
    }
  }

  String _time(TimeOfDay value) {
    return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }
}

class _MetaLine extends StatelessWidget {
  final IconData icon;
  final String text;

  const _MetaLine({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.48),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _LessonChip extends StatelessWidget {
  final String label;
  final Color color;

  const _LessonChip({
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
