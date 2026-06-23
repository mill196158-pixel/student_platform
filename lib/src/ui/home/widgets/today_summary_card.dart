import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';

class TodaySummaryCard extends StatelessWidget {
  final HomeDashboardData data;
  final VoidCallback onTap;

  const TodaySummaryCard({
    super.key,
    required this.data,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final remaining = data.remainingLessons;
    final title = data.hasLessonsToday
        ? 'Сегодня ${remaining.length} ${_lessonWord(remaining.length)}'
        : data.lessonsFinishedForToday
            ? 'Пары закончились'
            : 'Сегодня выходной';
    final subtitle = data.hasLessonsToday
        ? 'Кратко по расписанию на день'
        : data.lessonsFinishedForToday
            ? 'На сегодня больше ничего нет'
            : 'Пар нет, можно закрыть задания или отдохнуть';
    final lessons = remaining.take(2).toList();
    final emptyPreviewText = data.lessonsFinishedForToday
        ? 'Пары на сегодня закончились'
        : 'Сегодня пар нет';
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);
    final mutedForeground = foreground.withValues(alpha: isDark ? 0.78 : 0.68);
    final accent = isDark ? const Color(0xFFA78BFA) : const Color(0xFF7C63D8);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? const [Color(0xFF203041), Color(0xFF12202E)]
                    : const [Color(0xFFDCD0FA), Color(0xFFC5EFE5)],
              ),
              boxShadow: [
                BoxShadow(
                  color: (isDark ? Colors.black : const Color(0xFFD9CCF5))
                      .withValues(alpha: isDark ? 0.28 : 0.36),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Stack(
                children: [
                  Positioned(
                    right: -20,
                    top: -36,
                    child: _BlurBubble(size: 104, opacity: isDark ? 0.08 : 0.18),
                  ),
                  Positioned(
                    right: 38,
                    bottom: -36,
                    child: _BlurBubble(size: 76, opacity: isDark ? 0.06 : 0.13),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.18)
                                  : Colors.white.withValues(alpha: 0.64),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(
                              Icons.auto_awesome_rounded,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Сводка дня',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: mutedForeground,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w900,
                          height: 1.08,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: mutedForeground,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (lessons.isEmpty)
                        _NoLessonsPreview(text: emptyPreviewText)
                      else
                        ...lessons.map(
                          (lesson) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _LessonPreview(lesson: lesson),
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
    );
  }

  String _lessonWord(int count) {
    if (count % 10 == 1 && count % 100 != 11) return 'пара';
    if ([2, 3, 4].contains(count % 10) && ![12, 13, 14].contains(count % 100)) {
      return 'пары';
    }
    return 'пар';
  }
}

class _LessonPreview extends StatelessWidget {
  final Lesson lesson;

  const _LessonPreview({required this.lesson});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);
    final accent = isDark ? Colors.white : const Color(0xFF7C63D8);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (isDark ? Colors.white : const Color(0xFFD9CCF5))
              .withValues(alpha: isDark ? 0.16 : 0.45),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.18 : 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _time(lesson.start),
              style: TextStyle(
                color: accent,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lesson.subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _metaText(lesson),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground.withValues(alpha: 0.62),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _time(TimeOfDay value) {
    return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  String _metaText(Lesson lesson) {
    final parts = [
      '${lesson.pairNum}-я пара',
      if ((lesson.room ?? '').trim().isNotEmpty) lesson.room!.trim(),
      if ((lesson.teacher ?? '').trim().isNotEmpty) lesson.teacher!.trim(),
    ];
    return parts.join(' · ');
  }
}

class _NoLessonsPreview extends StatelessWidget {
  final String text;

  const _NoLessonsPreview({required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (isDark ? Colors.white : const Color(0xFFD9CCF5))
              .withValues(alpha: isDark ? 0.16 : 0.45),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.weekend_rounded, color: foreground, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: foreground.withValues(alpha: 0.82),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlurBubble extends StatelessWidget {
  final double size;
  final double opacity;

  const _BlurBubble({
    required this.size,
    required this.opacity,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: opacity),
      ),
    );
  }
}
