// lib/src/ui/schedule/lesson_details_screen.dart
import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import '../shared/workspace_page_header.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../info/subject_info_screen.dart';
import '../info/teacher_profile_screen.dart';
import 'models/lesson.dart';
import 'subject_diary/subject_diary.dart';
import 'subject_diary_screen.dart';

class LessonDetailsScreen extends StatelessWidget {
  final Lesson lesson;
  const LessonDetailsScreen({super.key, required this.lesson});

  @override
  Widget build(BuildContext context) {
    final dateStr = '${lesson.date.day.toString().padLeft(2, '0')}.'
        '${lesson.date.month.toString().padLeft(2, '0')}.${lesson.date.year}';
    final dateWithWeekday = '$dateStr (${_weekdayShort(lesson.date.weekday)})';

    final time = '${_fmt(lesson.start)} – ${_fmt(lesson.end)}';

    final room = (lesson.room ?? '').trim();
    final hasRoom = room.isNotEmpty;
    final isDistance =
        room.toLowerCase().contains('дист'); // «дист» → скрыть карту

    return Scaffold(
      body: Column(
        children: [
          const WorkspacePageHeader(title: 'Занятие'),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  ((MediaQuery.sizeOf(context).width - 800) / 2)
                      .clamp(16.0, double.infinity),
                  8,
                  ((MediaQuery.sizeOf(context).width - 800) / 2)
                      .clamp(16.0, double.infinity),
                  24),
              children: [
                // Большая карточка с типом и названием предмета
                _TypeAndTitleCard(
                  type: lesson.type,
                  subject: lesson.subject,
                ),

                // Дата
                _Info(
                  icon: Icons.event_outlined,
                  title: 'Дата',
                  value: dateWithWeekday,
                ),

                // Информация о предмете — 3-я позиция в списке
                _SubjectLinkCard(lesson: lesson),
                const SizedBox(height: 10),

                // Время
                _Info(
                  icon: Icons.schedule_outlined,
                  title: 'Время',
                  value: time,
                ),

                // Неделя / Пара
                _Info(
                  icon: Icons.school_outlined,
                  title: 'Неделя / Пара',
                  value: '${lesson.week}-я • ${lesson.pairNum}-я',
                ),

                // Преподаватель
                if ((lesson.teacher ?? '').isNotEmpty)
                  _TeacherLinkCard(lesson: lesson),

                // Аудитория + кнопка «На карте»
                if (hasRoom)
                  _RoomInfo(
                    value: room,
                    showMapButton: !isDistance,
                    onOpenMap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const _MapSpbgasuInlineScreen()),
                      );
                    },
                  ),

                const SizedBox(height: 14),

                // Облачка действий
                _ActionCloud(
                  icon: Icons.note_add_outlined,
                  title: 'Добавить запись по предмету',
                  subtitle: 'Быстрый конспект для этого предмета',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SubjectQuickNoteScreen(
                        subjectKey: lesson.subject.trim(),
                        args: lesson.hasSubjectLink
                            ? SubjectDiaryArgs(
                                subjectOfferingId: lesson.subjectOfferingId,
                                subjectId: lesson.subjectId,
                                subjectTitle: lesson.subject.trim(),
                                groupId: lesson.groupId,
                                semesterNumber: lesson.semesterNumber,
                                lessonId: lesson.id,
                                date: lesson.date,
                                legacySubjectKey: lesson.subject.trim(),
                              )
                            : null,
                        date: lesson.date,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _ActionCloud(
                  icon: Icons.menu_book_outlined,
                  title: 'Дневник предмета',
                  subtitle: 'Заметки и файлы, новые сверху',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => lesson.hasSubjectLink
                          ? SubjectDiaryScreen(
                              args: SubjectDiaryArgs(
                                subjectOfferingId: lesson.subjectOfferingId,
                                subjectId: lesson.subjectId,
                                subjectTitle: lesson.subject.trim(),
                                groupId: lesson.groupId,
                                semesterNumber: lesson.semesterNumber,
                                lessonId: lesson.id,
                                date: lesson.date,
                                legacySubjectKey: lesson.subject.trim(),
                              ),
                            )
                          : SubjectDiaryScreen(
                              subjectKey: lesson.subject.trim()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _weekdayShort(int weekday) {
    // 1..7 → ПН..ВС
    const ru = ['ПН', 'ВТ', 'СР', 'ЧТ', 'ПТ', 'СБ', 'ВС'];
    return ru[(weekday - 1).clamp(0, 6)];
  }
}

class _SubjectLinkCard extends StatelessWidget {
  final Lesson lesson;
  const _SubjectLinkCard({required this.lesson});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linked = lesson.hasSubjectLink;
    final offeringId = lesson.subjectOfferingId ?? '';

    return Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: linked
              ? () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SubjectInfoScreen(
                        title: lesson.subject,
                        subjectId: lesson.subjectId,
                        subjectOfferingId: offeringId,
                        lessonId: lesson.id,
                        groupId: lesson.groupId,
                        semesterNumber: lesson.semesterNumber,
                      ),
                    ),
                  )
              : null,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.lightbulb_outline,
                  color: linked
                      ? const Color(0xFF1E88E5)
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Информация о предмете',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: linked
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        linked
                            ? 'Краткая информация, материалы, чат и дневник предмета.'
                            : 'Информация по предмету пока не доступна.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: linked
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ));
  }
}

/// Большая карточка с типом занятия и названием предмета (как на скрине)
class _TypeAndTitleCard extends StatelessWidget {
  final LessonType type;
  final String subject;
  const _TypeAndTitleCard({required this.type, required this.subject});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final label = switch (type) {
      LessonType.lecture => 'Лекция',
      LessonType.practice => 'Практика',
      LessonType.lab => 'Лабораторная',
      LessonType.other => 'Занятие'
    };
    final color = switch (type) {
      LessonType.lecture => dark ? Colors.red.shade200 : Colors.red.shade800,
      LessonType.practice => dark ? Colors.blue.shade200 : Colors.blue.shade800,
      LessonType.lab => theme.colorScheme.primary,
      LessonType.other => theme.colorScheme.onSurfaceVariant,
    };
    return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (type != LessonType.other) ...[
            Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(8)),
                child: Text(label,
                    style:
                        theme.textTheme.labelMedium?.copyWith(color: color))),
            const SizedBox(height: 12),
          ],
          Text(subject, style: theme.textTheme.titleLarge),
        ]));
  }
}

class _Info extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  const _Info({required this.icon, required this.title, required this.value});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title, style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(value, style: theme.textTheme.bodyMedium),
              ])),
        ]));
  }
}

class _TeacherLinkCard extends StatelessWidget {
  final Lesson lesson;

  const _TeacherLinkCard({required this.lesson});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TeacherProfileScreen(
                teacherName: lesson.teacher!,
                subjectTitle: lesson.subject,
                semesterNumber: lesson.semesterNumber,
                subjectOfferingId: lesson.subjectOfferingId,
              ),
            ),
          ),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                TeacherDifficultyAvatar(
                  teacherName: lesson.teacher!,
                  size: 38,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Преподаватель',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        lesson.teacher!,
                        softWrap: true,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ));
  }
}

/// Строка "Аудитория": значение + «На карте» (если разрешено)
class _RoomInfo extends StatelessWidget {
  final String value;
  final bool showMapButton;
  final VoidCallback onOpenMap;
  const _RoomInfo(
      {required this.value,
      required this.showMapButton,
      required this.onOpenMap});
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.location_on_outlined,
              size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('Аудитория', style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(value, style: theme.textTheme.bodyMedium),
                if (showMapButton) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                      onPressed: onOpenMap,
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('На карте')),
                ],
              ])),
        ]));
  }
}

class _ActionCloud extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  const _ActionCloud({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 20, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                          height: 1.1,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ));
  }
}

class _MapSpbgasuInlineScreen extends StatefulWidget {
  const _MapSpbgasuInlineScreen({super.key});

  @override
  State<_MapSpbgasuInlineScreen> createState() =>
      _MapSpbgasuInlineScreenState();
}

class _MapSpbgasuInlineScreenState extends State<_MapSpbgasuInlineScreen> {
  late final WebViewController _controller;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            await _controller.runJavaScript("""
              try {
                document.querySelector('header')?.style.display='none';
                document.querySelector('footer')?.style.display='none';
              } catch (e) {}
            """);
            if (mounted) setState(() => _loaded = true);
          },
        ),
      )
      ..loadRequest(Uri.parse('https://map.spbgasu.ru/'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Карта СПБГАСУ'),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (!_loaded) const Center(child: ProductLoadingIndicator.page()),
        ],
      ),
    );
  }
}
