// lib/src/ui/schedule/lesson_details_screen.dart
import 'dart:ui' as ui;
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
          // ——— Шапка — «Занятие» покрупнее ———
          SizedBox(
            height: 128,
            child: _HeaderUnified(
              title: 'Занятие',
            ),
          ),
          const SizedBox(height: 12),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
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

    return InkWell(
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
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.lightbulb_outline,
              color: linked ? const Color(0xFF1E88E5) : Colors.black38,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Информация о предмете',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: linked ? Colors.black : Colors.black45,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    linked
                        ? 'Краткая информация, материалы, чат и дневник предмета.'
                        : 'Информация по предмету пока не доступна.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.black.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: linked ? Colors.black38 : Colors.black26,
            ),
          ],
        ),
      ),
    );
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
    final (bg, label) = switch (type) {
      LessonType.lecture => (const Color(0xFFFFE6E5), 'Лекция'),
      LessonType.practice => (const Color(0xFFE6F0FF), 'Практика'),
      LessonType.lab => (const Color(0xFFF1E6FF), 'Лабораторная'),
      LessonType.other => (theme.colorScheme.surface, 'Занятие'),
    };
    final chipColor = switch (type) {
      LessonType.lecture => const Color(0xFFE53935),
      LessonType.practice => const Color(0xFF1E88E5),
      LessonType.lab => const Color(0xFF8E24AA),
      LessonType.other => Colors.black54,
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, 3))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // чип типа
          DecoratedBox(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                label,
                style: TextStyle(
                  color: chipColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  letterSpacing: .2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subject,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  fontSize:
                      (Theme.of(context).textTheme.titleLarge?.fontSize ?? 20) +
                          2,
                  height: 1.1,
                  color: Colors.black,
                ),
          ),
        ],
      ),
    );
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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.black.withOpacity(0.55),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.black,
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
}

class _TeacherLinkCard extends StatelessWidget {
  final Lesson lesson;

  const _TeacherLinkCard({required this.lesson});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
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
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
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
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lesson.teacher!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.black,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right_rounded,
              color: Colors.black38,
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка "Аудитория": значение + «На карте» (если разрешено)
class _RoomInfo extends StatelessWidget {
  final String value;
  final bool showMapButton;
  final VoidCallback onOpenMap;
  const _RoomInfo({
    required this.value,
    required this.showMapButton,
    required this.onOpenMap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.location_on_outlined,
              size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Аудитория',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.black.withOpacity(0.55),
                    )),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.black,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (showMapButton) ...[
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        onPressed: onOpenMap,
                        icon: const Icon(Icons.map_outlined, size: 16),
                        label: const Text('На карте'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          shape: const StadiumBorder(),
                          textStyle: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                          elevation: 1,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
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
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                      height: 1.1,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black.withOpacity(.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: Colors.black54),
          ],
        ),
      ),
    );
  }
}

/// Унифицированная шапка
class _HeaderUnified extends StatelessWidget {
  final String title;
  final String? subtitle; // не используем
  const _HeaderUnified({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white,
                theme.colorScheme.primary.withOpacity(0.06),
                theme.colorScheme.primary.withOpacity(0.12)
              ],
              stops: const [0.0, 0.62, 1.0],
            ),
          ),
        ),
        IgnorePointer(
          child: Stack(children: [
            Positioned(
                left: -40,
                top: -20,
                child: _GlowCircle(
                    diameter: 140,
                    color: theme.colorScheme.primary.withOpacity(0.10))),
            Positioned(
                right: -30,
                bottom: -30,
                child: _GlowCircle(
                    diameter: 160, color: Colors.white.withOpacity(0.55))),
          ]),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Align(
              alignment: const Alignment(-1, 0.25),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const _RoundBackButton(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Colors.black,
                                height: 1.05,
                              ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GlowCircle extends StatelessWidget {
  final double diameter;
  final Color color;
  const _GlowCircle({required this.diameter, required this.color});
  @override
  Widget build(BuildContext context) => ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
        ),
      );
}

/// Круглая кнопка «Назад» как в чате
class _RoundBackButton extends StatelessWidget {
  const _RoundBackButton();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 10,
              offset: const Offset(0, 3)),
        ],
      ),
      child: IconButton(
        tooltip: 'Назад',
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}

/// Встроенная карта СПбГАСУ в WebView.
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
        leadingWidth: 64,
        leading: const Padding(
          padding: EdgeInsets.only(left: 12),
          child: _RoundBackButton(),
        ),
        title: const Text('Карта СПБГАСУ'),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (!_loaded) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
