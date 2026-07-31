import 'package:flutter/material.dart';
import '../models/lesson.dart';

/// Живой статус пары относительно текущего времени.
enum LessonLiveStatus { none, ongoing, next }

const Color _kOngoingColor = Color(0xFF10B981);

class LessonCard extends StatelessWidget {
  final Lesson lesson;
  final VoidCallback onTap;
  final LessonLiveStatus status;
  const LessonCard({
    super.key,
    required this.lesson,
    required this.onTap,
    this.status = LessonLiveStatus.none,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time = '${_fmt(lesson.start)} – ${_fmt(lesson.end)}';
    final (label, color) = _badgeFor(lesson);

    final isOngoing = status == LessonLiveStatus.ongoing;
    final isNext = status == LessonLiveStatus.next;
    final borderColor = isOngoing ? _kOngoingColor : color;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: isOngoing
              ? _kOngoingColor.withValues(alpha: 0.06)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
                color: (isOngoing ? _kOngoingColor : Colors.black)
                    .withValues(alpha: isOngoing ? 0.14 : 0.06),
                blurRadius: 14,
                offset: const Offset(0, 3)),
          ],
          border: Border(
              left: BorderSide(
                  color: borderColor.withValues(alpha: 0.85),
                  width: isOngoing ? 5 : 4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isOngoing || isNext) ...[
              _LiveRibbon(ongoing: isOngoing),
              const SizedBox(height: 10),
            ],
            Row(
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
                          ?.copyWith(color: Colors.black.withValues(alpha: 0.55))),
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
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.black.withValues(alpha: 0.70)),
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
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.black.withValues(alpha: 0.70)),
                      )),
                    ]),
                  ],
                ],
              ),
            ),
          ],
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

/// Лента статуса пары: «Идёт сейчас» (с пульсацией) / «Следующая пара».
class _LiveRibbon extends StatelessWidget {
  final bool ongoing;
  const _LiveRibbon({required this.ongoing});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final color = ongoing ? _kOngoingColor : primary;
    final text = ongoing ? 'Идёт сейчас' : 'Следующая пара';

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ongoing
                ? _PulseDot(color: color)
                : Container(
                    width: 8,
                    height: 8,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
            const SizedBox(width: 7),
            Text(
              text,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  final Color color;
  const _PulseDot({required this.color});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = _c.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 8 + 6 * t,
                height: 8 + 6 * t,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.28 * (1 - t)),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
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
              color: color.withValues(alpha: 0.28),
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
