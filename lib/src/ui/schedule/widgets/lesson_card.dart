import 'package:flutter/material.dart';
import '../models/lesson.dart';

class LessonCard extends StatelessWidget {
  final Lesson lesson;
  final VoidCallback onTap;
  const LessonCard({super.key, required this.lesson, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = '${_fmt(lesson.start)} – ${_fmt(lesson.end)}';
    final (label, color) = _badgeFor(lesson);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 14,
                offset: const Offset(0, 3)),
          ],
          border: Border(
              left: BorderSide(color: color.withOpacity(0.85), width: 4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Время
            SizedBox(
              width: 86,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(time,
                      style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 6),
                  Text('${lesson.pairNum}-я пара',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: Colors.black.withOpacity(0.55))),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Контент
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Text(
                        lesson.subject,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                            height: 1.08),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (label.isNotEmpty) _Badge(text: label, color: color),
                  ]),
                  const SizedBox(height: 6),
                  if ((lesson.teacher ?? '').isNotEmpty)
                    Row(children: [
                      const Icon(Icons.person_outline, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(
                        lesson.teacher!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.black.withOpacity(0.70)),
                      )),
                    ]),
                  if ((lesson.room ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.location_on_outlined, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(
                        lesson.room!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.black.withOpacity(0.70)),
                      )),
                    ]),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  (String, Color) _badgeFor(Lesson l) {
    switch (l.type) {
      case LessonType.lecture:
        return ('Лекция', const Color(0xFFE53935));
      case LessonType.practice:
        return ('Практика', const Color(0xFF1E88E5));
      case LessonType.lab:
        return ('Лабораторная', const Color(0xFF8E24AA));
      case LessonType.other:
        return ('', const Color(0xFF9E9E9E));
    }
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
              color: color.withOpacity(0.28),
              blurRadius: 8,
              offset: const Offset(0, 3))
        ],
      ),
      child: Text(text,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}
