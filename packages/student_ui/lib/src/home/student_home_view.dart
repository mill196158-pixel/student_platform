import 'package:flutter/material.dart';

import 'home_preview_models.dart';
import 'widgets/student_home_news_card.dart';

class StudentHomeView extends StatelessWidget {
  const StudentHomeView({
    required this.data,
    this.notificationCount = 0,
    this.onRefresh,
    this.onNotificationsTap,
    this.onNewsTap,
    this.onSummaryTap,
    this.onGroupActionTap,
    this.onGroupActionDelete,
    this.onAssignmentsOpen,
    this.onAssignmentTap,
    this.onAssignmentDoneTap,
    this.onHelpTap,
    this.hiddenAssignmentIds = const {},
    this.markingDoneAssignmentIds = const {},
    this.selectedNewsId,
    this.adminNewsHighlightColor,
    this.bottomNavigationBar,
    super.key,
  });

  final StudentHomeData data;
  final int notificationCount;
  final Future<void> Function()? onRefresh;
  final VoidCallback? onNotificationsTap;
  final ValueChanged<int>? onNewsTap;
  final VoidCallback? onSummaryTap;
  final ValueChanged<StudentHomeGroupAction>? onGroupActionTap;
  final ValueChanged<StudentHomeGroupAction>? onGroupActionDelete;
  final VoidCallback? onAssignmentsOpen;
  final ValueChanged<StudentHomeAssignment>? onAssignmentTap;
  final ValueChanged<StudentHomeAssignment>? onAssignmentDoneTap;
  final VoidCallback? onHelpTap;
  final Set<String> hiddenAssignmentIds;
  final Set<String> markingDoneAssignmentIds;
  final String? selectedNewsId;
  final Color? adminNewsHighlightColor;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scrollView = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: _HomeHeader(
            profile: data.profile,
            currentDate: data.currentDate,
            notificationCount: notificationCount,
            onNotificationsTap: onNotificationsTap,
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 20),
            child: StudentHomeNewsFeed(
              news: data.news,
              onNewsTap: onNewsTap,
              selectedNewsId: selectedNewsId,
              adminHighlightColor: adminNewsHighlightColor,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 70),
            child: _TodaySummaryCard(
              data: data,
              onTap: onSummaryTap,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 120),
            child: _AssignmentsSection(
              data: data,
              hiddenAssignmentIds: hiddenAssignmentIds,
              markingDoneAssignmentIds: markingDoneAssignmentIds,
              onOpen: onAssignmentsOpen,
              onAssignmentTap: onAssignmentTap,
              onAssignmentDoneTap: onAssignmentDoneTap,
              onGroupActionTap: onGroupActionTap,
              onGroupActionDelete: onGroupActionDelete,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 170),
            child: _HelpCard(onTap: onHelpTap),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF101820) : const Color(0xFFFAF8FC),
      bottomNavigationBar: bottomNavigationBar,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? const [Color(0xFF101820), Color(0xFF111827)]
                : const [Color(0xFFFAF8FC), Color(0xFFF7FBFA)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: onRefresh == null
              ? scrollView
              : RefreshIndicator(onRefresh: onRefresh!, child: scrollView),
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.profile,
    required this.currentDate,
    required this.notificationCount,
    required this.onNotificationsTap,
  });

  final StudentHomeProfile profile;
  final DateTime currentDate;
  final int notificationCount;
  final VoidCallback? onNotificationsTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = [
      if (profile.groupName.isNotEmpty) profile.groupName,
      'сегодня ${_formatDayMonth(currentDate)}',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Привет, ${profile.displayName} 👋',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.06,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _RoundNotificationButton(
            onTap: onNotificationsTap,
            badgeCount: notificationCount,
          ),
        ],
      ),
    );
  }
}

class _RoundNotificationButton extends StatelessWidget {
  const _RoundNotificationButton({
    required this.onTap,
    required this.badgeCount,
  });

  final VoidCallback? onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color:
                  isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isDark
                    ? Colors.white10
                    : Colors.black.withValues(alpha: 0.04),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Icon(
              Icons.notifications_none_rounded,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
            ),
          ),
        ),
        if (badgeCount > 0)
          Positioned(
            right: -4,
            top: -5,
            child: _NotificationBadge(count: badgeCount),
          ),
      ],
    );
  }
}

class _NotificationBadge extends StatelessWidget {
  const _NotificationBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 21, minHeight: 21),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.colorScheme.primary, const Color(0xFFE35D7A)],
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.surface, width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFE35D7A).withValues(alpha: 0.28),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        count > 9 ? '9+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

class _TodaySummaryCard extends StatelessWidget {
  const _TodaySummaryCard({
    required this.data,
    required this.onTap,
  });

  final StudentHomeData data;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final count = data.lessons.length;
    final title = count > 0
        ? 'Сегодня $count ${_lessonWord(count)}'
        : data.lessonsFinishedForToday
            ? 'Пары закончились'
            : 'Сегодня выходной';
    final subtitle = count > 0
        ? 'Кратко по расписанию на день'
        : data.lessonsFinishedForToday
            ? 'На сегодня больше ничего нет'
            : 'Пар нет, можно закрыть задания или отдохнуть';
    final emptyText = data.lessonsFinishedForToday
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
                    child: _GlowBubble(
                      size: 104,
                      opacity: isDark ? 0.08 : 0.18,
                    ),
                  ),
                  Positioned(
                    right: 38,
                    bottom: -36,
                    child: _GlowBubble(
                      size: 76,
                      opacity: isDark ? 0.06 : 0.13,
                    ),
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
                              color: Colors.white.withValues(
                                alpha: isDark ? 0.18 : 0.64,
                              ),
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
                      // Day summary = pairs/schedule only. Group actions
                      // (topic / collection) belong under «Ближайшие дела».
                      if (data.lessons.isEmpty)
                        _NoLessonsPreview(text: emptyText)
                      else
                        ...data.lessons.take(2).map(
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
}

class _LessonPreview extends StatelessWidget {
  const _LessonPreview({required this.lesson});

  final StudentHomeLesson lesson;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);
    final accent = isDark ? Colors.white : const Color(0xFF7C63D8);
    final meta = [
      '${lesson.pairNumber}-я пара',
      if (lesson.room.trim().isNotEmpty) lesson.room.trim(),
      if (lesson.teacher.trim().isNotEmpty) lesson.teacher.trim(),
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.62),
        borderRadius: BorderRadius.circular(16),
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
              _formatTime(lesson.start),
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
                  meta,
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
}

class _GroupActionPreview extends StatelessWidget {
  const _GroupActionPreview({
    required this.action,
    this.onTap,
    this.onDelete,
  });

  final StudentHomeGroupAction action;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);
    final accent = isDark ? const Color(0xFFA78BFA) : const Color(0xFF7C63D8);
    final displayTitle =
        (action.followUpTitle ?? '').trim().isNotEmpty
            ? action.followUpTitle!.trim()
            : action.title;
    final listTitle = action.title.trim();
    final hasPickedTopic = (action.followUpTitle ?? '').trim().isNotEmpty;
    // Type first (Тема / Сбор). List name is separate — «Доклад» ≠ задание.
    final kind = action.isTopic
        ? 'Тема'
        : (action.isCollection
            ? 'Сбор'
            : (action.kindLabel.trim().isEmpty
                ? 'Дело'
                : action.kindLabel.trim()));
    final meta = [
      kind,
      if (hasPickedTopic && listTitle.isNotEmpty) 'список «$listTitle»',
      if ((action.teamName ?? '').trim().isNotEmpty) action.teamName!.trim(),
      action.deadlineText,
    ].join(' · ');
    final status = (action.statusLine ?? '').trim();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.78),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Icon(
                action.isTopic
                    ? Icons.edit_note_rounded
                    : Icons.payments_outlined,
                color: accent,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle,
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
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.62),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (status.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: const Color(0xFF2F9D84),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onDelete != null)
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.more_vert_rounded,
                    size: 18,
                    color: foreground.withValues(alpha: 0.55),
                  ),
                  onSelected: (v) {
                    if (v == 'delete') onDelete!();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'delete',
                      child: Text('Удалить'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoLessonsPreview extends StatelessWidget {
  const _NoLessonsPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.62),
        borderRadius: BorderRadius.circular(16),
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

class _AssignmentsSection extends StatelessWidget {
  const _AssignmentsSection({
    required this.data,
    required this.hiddenAssignmentIds,
    required this.markingDoneAssignmentIds,
    required this.onOpen,
    required this.onAssignmentTap,
    required this.onAssignmentDoneTap,
    this.onGroupActionTap,
    this.onGroupActionDelete,
  });

  final StudentHomeData data;
  final Set<String> hiddenAssignmentIds;
  final Set<String> markingDoneAssignmentIds;
  final VoidCallback? onOpen;
  final ValueChanged<StudentHomeAssignment>? onAssignmentTap;
  final ValueChanged<StudentHomeAssignment>? onAssignmentDoneTap;
  final ValueChanged<StudentHomeGroupAction>? onGroupActionTap;
  final ValueChanged<StudentHomeGroupAction>? onGroupActionDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final visibleAssignments = data.assignments
        .where((item) => !hiddenAssignmentIds.contains(item.id))
        .toList();
    // One merged, deadline-sorted feed with a shared cap (compact section).
    final upcoming = <_UpcomingItem>[
      for (final a in visibleAssignments) _UpcomingItem.assignment(a),
      // Confirmed money transfers leave the upcoming list (done).
      for (final g in data.groupActions.where((e) => !e.isCompleted))
        _UpcomingItem.groupAction(g),
    ]..sort((a, b) {
        // Dated items first (soonest → latest); undated last so they do not
        // steal the shared 4-item cap from real deadlines.
        final aAt = a.sortAt;
        final bAt = b.sortAt;
        if (aAt == null && bAt == null) return 0;
        if (aAt == null) return 1;
        if (bAt == null) return -1;
        return aAt.compareTo(bAt);
      });
    final capped = upcoming.take(4).toList();
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);
    final mutedForeground = foreground.withValues(alpha: isDark ? 0.76 : 0.66);
    final accent = isDark ? const Color(0xFFF3C774) : const Color(0xFFB58B3B);
    final subtitle = _upcomingSubtitle(capped);

    // Section title sits outside the tinted card (not trapped in an oval).
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onOpen,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.event_note_rounded, color: accent, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ближайшие дела',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w900,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: mutedForeground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? const [Color(0xFF2B2932), Color(0xFF182331)]
                      : const [Color(0xFFFFF1D2), Color(0xFFEAF7F2)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: (isDark ? Colors.black : const Color(0xFFEFD9AC))
                        .withValues(alpha: isDark ? 0.24 : 0.22),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: capped.isEmpty
                    ? const _EmptyAssignments()
                    : Column(
                        children: [
                          for (var i = 0; i < capped.length; i++)
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: i == capped.length - 1 ? 0 : 8,
                              ),
                              child: capped[i].when(
                                assignment: (a) => _TaskPreviewCard(
                                  item: a,
                                  onTap: onAssignmentTap == null
                                      ? null
                                      : () => onAssignmentTap!(a),
                                  onDoneTap: onAssignmentDoneTap == null
                                      ? null
                                      : () => onAssignmentDoneTap!(a),
                                  markingDone:
                                      markingDoneAssignmentIds.contains(a.id),
                                ),
                                groupAction: (g) => _GroupActionPreview(
                                  action: g,
                                  onTap: onGroupActionTap == null
                                      ? null
                                      : () => onGroupActionTap!(g),
                                  onDelete: (onGroupActionDelete != null &&
                                          g.canDelete)
                                      ? () => onGroupActionDelete!(g)
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpcomingItem {
  const _UpcomingItem._({
    this.assignment,
    this.groupAction,
    required this.sortAt,
  });

  factory _UpcomingItem.assignment(StudentHomeAssignment a) => _UpcomingItem._(
        assignment: a,
        sortAt: a.dueAt,
      );

  factory _UpcomingItem.groupAction(StudentHomeGroupAction g) =>
      _UpcomingItem._(
        groupAction: g,
        sortAt: g.occursAt,
      );

  final StudentHomeAssignment? assignment;
  final StudentHomeGroupAction? groupAction;
  final DateTime? sortAt;

  T when<T>({
    required T Function(StudentHomeAssignment a) assignment,
    required T Function(StudentHomeGroupAction g) groupAction,
  }) {
    if (this.assignment != null) return assignment(this.assignment!);
    return groupAction(this.groupAction!);
  }
}

class _TaskPreviewCard extends StatelessWidget {
  const _TaskPreviewCard({
    required this.item,
    required this.onTap,
    required this.onDoneTap,
    required this.markingDone,
  });

  final StudentHomeAssignment item;
  final VoidCallback? onTap;
  final VoidCallback? onDoneTap;
  final bool markingDone;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2937);
    final statusColor =
        item.isDone ? const Color(0xFF2F9D84) : const Color(0xFFB58B3B);
    final meta = [
      'Задание',
      if (item.subject.trim().isNotEmpty) item.subject.trim(),
      item.deadline,
      _statusText(item),
    ].where((e) => e.trim().isNotEmpty).join(' · ');

    // Compact row — same density as day-summary lesson/action previews.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: isDark ? 0.14 : 0.78),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            _DoneCheckButton(
              done: item.isDone,
              loading: markingDone,
              color: statusColor,
              onTap: onDoneTap,
              compact: true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor.withValues(alpha: 0.62),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneCheckButton extends StatelessWidget {
  const _DoneCheckButton({
    required this.done,
    required this.loading,
    required this.color,
    required this.onTap,
    this.compact = false,
  });

  final bool done;
  final bool loading;
  final Color color;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillColor = done
        ? const Color(0xFF2F9D84)
        : color.withValues(alpha: isDark ? 0.20 : 0.13);
    final iconColor = done ? Colors.white : color;
    final size = compact ? 36.0 : 48.0;
    final radius = compact ? 12.0 : 16.0;
    final iconSize = compact ? 20.0 : 27.0;
    return Tooltip(
      message: done ? 'Задание выполнено' : 'Отметить выполненным',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading ? null : onTap,
          borderRadius: BorderRadius.circular(radius),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(radius),
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
                      width: compact ? 14 : 18,
                      height: compact ? 14 : 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: iconColor,
                      ),
                    )
                  : Icon(Icons.check_rounded, color: iconColor, size: iconSize),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyAssignments extends StatelessWidget {
  const _EmptyAssignments();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF182331) : Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            color: theme.colorScheme.primary,
            size: 36,
          ),
          const SizedBox(height: 10),
          const Text(
            'Пока нет ближайших заданий',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          Text(
            'Если староста добавит задание в чат, оно появится здесь',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
            ),
          ),
        ],
      ),
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final bodyColor =
        isDark ? Colors.white.withValues(alpha: 0.72) : const Color(0xFF64748B);
    final accent = isDark ? const Color(0xFFA78BFA) : const Color(0xFF7C63D8);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: isDark
                ? null
                : const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFFBFF), Color(0xFFF3EEF9)],
                  ),
            color: isDark ? const Color(0xFF182331) : null,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.05),
                blurRadius: 22,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: isDark ? 0.18 : 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(Icons.psychology_alt_outlined, color: accent),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Застрял с заданием?',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: titleColor,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Можно разобрать задачу, подготовиться к сдаче или понять, с чего начать.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: bodyColor,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton(
                      onPressed: onTap,
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      child: const Text(
                        'Получить помощь',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
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

class _GlowBubble extends StatelessWidget {
  const _GlowBubble({required this.size, required this.opacity});

  final double size;
  final double opacity;

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

class _AnimatedEntry extends StatelessWidget {
  const _AnimatedEntry({required this.child, required this.delay});

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delay.inMilliseconds),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        final delayedValue =
            ((value * (420 + delay.inMilliseconds)) - delay.inMilliseconds)
                    .clamp(0.0, 420.0) /
                420.0;
        return Opacity(
          opacity: delayedValue,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - delayedValue)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

String _formatDayMonth(DateTime date) {
  const months = [
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  return '${date.day} ${months[date.month - 1]}';
}

String _formatTime(TimeOfDay value) {
  return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}

String _lessonWord(int count) {
  if (count % 10 == 1 && count % 100 != 11) return 'пара';
  if ([2, 3, 4].contains(count % 10) && ![12, 13, 14].contains(count % 100)) {
    return 'пары';
  }
  return 'пар';
}

String _assignmentWord(int count) {
  if (count % 10 == 1 && count % 100 != 11) return 'задание';
  if ([2, 3, 4].contains(count % 10) && ![12, 13, 14].contains(count % 100)) {
    return 'задания';
  }
  return 'заданий';
}

String _topicWord(int count) {
  if (count % 10 == 1 && count % 100 != 11) return 'тема';
  if ([2, 3, 4].contains(count % 10) && ![12, 13, 14].contains(count % 100)) {
    return 'темы';
  }
  return 'тем';
}

String _collectionWord(int count) {
  if (count % 10 == 1 && count % 100 != 11) return 'сбор';
  if ([2, 3, 4].contains(count % 10) && ![12, 13, 14].contains(count % 100)) {
    return 'сбора';
  }
  return 'сборов';
}

String _upcomingSubtitle(List<_UpcomingItem> items) {
  if (items.isEmpty) return 'Здесь появятся ближайшие дедлайны';
  var assignments = 0;
  var topics = 0;
  var collections = 0;
  for (final item in items) {
    item.when(
      assignment: (_) => assignments++,
      groupAction: (g) {
        if (g.isTopic) {
          topics++;
        } else if (g.isCollection) {
          collections++;
        }
      },
    );
  }
  final parts = <String>[
    if (assignments > 0) '$assignments ${_assignmentWord(assignments)}',
    if (topics > 0) '$topics ${_topicWord(topics)}',
    if (collections > 0) '$collections ${_collectionWord(collections)}',
  ];
  if (parts.isEmpty) {
    return '${items.length} ${_dealWord(items.length)} в списке';
  }
  return parts.join(' · ');
}

String _dealWord(int count) {
  if (count % 10 == 1 && count % 100 != 11) return 'дело';
  if ([2, 3, 4].contains(count % 10) && ![12, 13, 14].contains(count % 100)) {
    return 'дела';
  }
  return 'дел';
}

String _statusText(StudentHomeAssignment item) {
  if (item.isDone || item.status == StudentHomeAssignmentStatus.done) {
    return 'выполнено';
  }
  return switch (item.status) {
    StudentHomeAssignmentStatus.inProgress => 'в процессе',
    StudentHomeAssignmentStatus.notStarted => 'не начато',
    StudentHomeAssignmentStatus.done => 'выполнено',
  };
}
