import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/home/widgets/help_card.dart';
import 'package:student_platform/src/ui/home/widgets/home_header.dart';
import 'package:student_platform/src/ui/home/widgets/news_feed_section.dart';
import 'package:student_platform/src/ui/home/widgets/news_story_sheet.dart';
import 'package:student_platform/src/ui/home/widgets/task_preview_card.dart';
import 'package:student_platform/src/ui/home/widgets/today_summary_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final HomeDashboardService _service = HomeDashboardService();

  HomeDashboardData? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final data = await _service.load();
      if (!mounted) return;
      setState(() => _data = data);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF101820) : const Color(0xFFFAF8FC),
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
          child: RefreshIndicator(
            onRefresh: _load,
            child: _body(),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && _data == null) {
      return const _LoadingDashboard();
    }

    if (_error != null && _data == null) {
      return _ErrorDashboard(
        onRetry: _load,
        message:
            'Не удалось загрузить главную. Потяните вниз или попробуйте ещё раз.',
      );
    }

    final data = _data;
    if (data == null) return const SizedBox.shrink();

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: HomeHeader(
            profile: data.profile,
            onNotificationsTap: () => _showNotifications(data),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 20),
            child: NewsFeedSection(
              news: data.news,
              onNewsTap: (index) => _showNewsFeed(data.news, index),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 70),
            child: TodaySummaryCard(data: data),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 120),
            child: _AssignmentsSection(
              data: data,
              onOpen: () => context.push('/my-diary'),
              onAssignmentTap: _showAssignmentDetails,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 170),
            child: HelpCard(
              onTap: _showHelpDetails,
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  void _showNewsFeed(List<HomeNewsItem> news, int initialIndex) {
    if (news.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) => NewsStorySheet(
        news: news,
        initialIndex: initialIndex,
      ),
    );
  }

  void _showNotifications(HomeDashboardData data) {
    final lessonsText = data.hasLessonsToday
        ? 'Сегодня ${data.lessonsCount} ${_lessonWord(data.lessonsCount)}'
        : 'Сегодня пар нет';
    final assignmentsText = data.assignmentsCount > 0
        ? 'Есть ${data.assignmentsCount} ближайшие ${_assignmentWord(data.assignmentsCount)}'
        : 'Ближайших дедлайнов пока нет';
    final time = DateFormat('HH:mm', 'ru_RU').format(DateTime.now());
    final notifications = <Widget>[
      _NotificationLine(
        title: 'Расписание',
        text: lessonsText,
        time: time,
        icon: Icons.today_rounded,
        color: const Color(0xFF7C63D8),
      ),
      _NotificationLine(
        title: 'Задания',
        text: assignmentsText,
        time: time,
        icon: Icons.task_alt_rounded,
        color: const Color(0xFFB58B3B),
      ),
      const _NotificationLine(
        title: 'Материалы',
        text: 'Новые материалы появятся в разделе «Информация»',
        time: 'сегодня',
        icon: Icons.folder_copy_outlined,
        color: Color(0xFF2F9D84),
      ),
      const _NotificationLine(
        title: 'Система',
        text: 'Главная страница обновлена',
        time: 'сегодня',
        icon: Icons.auto_awesome_rounded,
        color: Color(0xFF8A72D8),
      ),
    ];

    _showDetailsSheet(
      title: 'Уведомления',
      icon: Icons.notifications_none_rounded,
      accent: const Color(0xFF7C63D8),
      children: notifications.isEmpty
          ? const [
              _NotificationEmptyState(),
            ]
          : notifications,
    );
  }

  void _showAssignmentDetails(HomeAssignmentPreview item) {
    final assignment = item.assignment;
    _showDetailsSheet(
      title: assignment.title,
      icon: Icons.task_alt_rounded,
      accent: const Color(0xFFB58B3B),
      children: [
        _InfoLine(
          label: 'Предмет',
          value: item.teamName.isEmpty ? 'Команда' : item.teamName,
        ),
        _InfoLine(label: 'Дедлайн', value: _deadlineText(item)),
        _InfoLine(label: 'Статус', value: _assignmentStatusText(item)),
        const SizedBox(height: 10),
        Text(
          assignment.description.trim().isEmpty
              ? 'Описание пока не добавлено.'
              : assignment.description,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.45,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.74),
              ),
        ),
      ],
    );
  }

  void _showHelpDetails() {
    _showDetailsSheet(
      title: 'Помощь с заданием',
      icon: Icons.psychology_alt_outlined,
      accent: const Color(0xFF8A72D8),
      children: [
        Text(
          'Здесь можно будет разобрать задачу, подготовиться к сдаче или понять, с чего начать. Раздел помощи будет добавлен позже.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                height: 1.45,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.74),
              ),
        ),
      ],
    );
  }

  Future<void> _showDetailsSheet({
    required String title,
    required IconData icon,
    required Color accent,
    required List<Widget> children,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, color: accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          height: 1.12,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ...children,
              ],
            ),
          ),
        );
      },
    );
  }

  String _deadlineText(HomeAssignmentPreview item) {
    final dueAt = item.assignment.dueAt;
    if (dueAt != null) return DateFormat('d MMMM', 'ru_RU').format(dueAt);
    final due = item.assignment.due?.trim();
    if (due != null && due.isNotEmpty) return due;
    return 'Без срока';
  }

  String _assignmentStatusText(HomeAssignmentPreview item) {
    if (item.isDone) return 'выполнено';
    switch (item.assignment.status) {
      case 'in_progress':
        return 'в процессе';
      case 'published':
      case 'draft':
      case null:
      case '':
        return 'не начато';
      default:
        return item.assignment.status!;
    }
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
}

class _AssignmentsSection extends StatelessWidget {
  final HomeDashboardData data;
  final VoidCallback onOpen;
  final ValueChanged<HomeAssignmentPreview> onAssignmentTap;

  const _AssignmentsSection({
    required this.data,
    required this.onOpen,
    required this.onAssignmentTap,
  });

  @override
  Widget build(BuildContext context) {
    final assignments = data.assignments.take(4).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
            title: 'Ближайшие задания',
            actionLabel: 'Открыть',
            onAction: onOpen,
          ),
          const SizedBox(height: 12),
          if (assignments.isEmpty)
            const _EmptyState(
              title: 'Пока нет ближайших заданий',
              text: 'Если староста добавит задание в чат, оно появится здесь',
              icon: Icons.check_circle_outline_rounded,
            )
          else
            ...assignments.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TaskPreviewCard(
                  item: item,
                  onTap: () => onAssignmentTap(item),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;

  const _InfoLine({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              '$label:',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.56),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationLine extends StatelessWidget {
  final String title;
  final String text;
  final String time;
  final IconData icon;
  final Color color;

  const _NotificationLine({
    required this.title,
    required this.text,
    required this.time,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Text(
                      time,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.48),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.64),
                    height: 1.3,
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

class _NotificationEmptyState extends StatelessWidget {
  const _NotificationEmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        children: [
          Icon(
            Icons.notifications_off_outlined,
            size: 42,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.34),
          ),
          const SizedBox(height: 10),
          Text(
            'Пока нет уведомлений',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _SectionTitle({
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                height: 1.1,
                color: titleColor,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF7C63D8),
              ),
              child: Text(
                actionLabel!,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String text;
  final IconData icon;

  const _EmptyState({
    required this.title,
    required this.text,
    this.icon = Icons.event_available_outlined,
  });

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
        border: Border.all(
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedEntry extends StatelessWidget {
  final Widget child;
  final Duration delay;

  const _AnimatedEntry({
    required this.child,
    required this.delay,
  });

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

class _LoadingDashboard extends StatelessWidget {
  const _LoadingDashboard();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: const [
        _SkeletonLine(width: 180, height: 28),
        SizedBox(height: 10),
        _SkeletonLine(width: 240, height: 18),
        SizedBox(height: 18),
        _SkeletonBlock(height: 82, radius: 22),
        SizedBox(height: 16),
        _SkeletonBlock(height: 190, radius: 28),
        SizedBox(height: 24),
        _SkeletonLine(width: 132, height: 24),
        SizedBox(height: 12),
        _SkeletonBlock(height: 148, radius: 24),
        SizedBox(height: 14),
        _SkeletonBlock(height: 98, radius: 22),
        SizedBox(height: 12),
        _SkeletonBlock(height: 98, radius: 22),
      ],
    );
  }
}

class _ErrorDashboard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorDashboard({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.18),
        Icon(Icons.cloud_off_rounded, size: 56, color: theme.colorScheme.error),
        const SizedBox(height: 18),
        Text(
          'Что-то пошло не так',
          textAlign: TextAlign.center,
          style:
              theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.62),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Повторить'),
          ),
        ),
      ],
    );
  }
}

class _SkeletonBlock extends StatelessWidget {
  final double height;
  final double radius;

  const _SkeletonBlock({
    required this.height,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return _SkeletonBase(
      child: SizedBox(height: height, width: double.infinity),
      radius: radius,
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  final double width;
  final double height;

  const _SkeletonLine({
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return _SkeletonBase(
      radius: height / 2,
      child: SizedBox(width: width, height: height),
    );
  }
}

class _SkeletonBase extends StatelessWidget {
  final Widget child;
  final double radius;

  const _SkeletonBase({
    required this.child,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.45, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color:
                  isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
