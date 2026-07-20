import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/home/widgets/help_card.dart';
import 'package:student_platform/src/ui/home/widgets/home_header.dart';
import 'package:student_platform/src/ui/home/widgets/news_feed_section.dart';
import 'package:student_platform/src/ui/home/widgets/news_story_sheet.dart';
import 'package:student_platform/src/ui/home/widgets/task_preview_card.dart';
import 'package:student_platform/src/ui/navigation/main_tab_scope.dart';
import 'package:student_platform/src/ui/home/widgets/today_summary_card.dart';
import 'package:student_platform/src/ui/notifications/in_app_toast_host.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final HomeDashboardService _service = HomeDashboardService();
  final AppNotificationsApi _notificationsApi = AppNotificationsApi();

  HomeDashboardData? _data;
  Object? _error;
  bool _loading = true;
  int _unreadNotificationCount = 0;
  final Set<String> _hiddenDoneAssignmentIds = {};
  final Set<String> _markingDoneAssignmentIds = {};
  StreamSubscription<InAppNotificationEvent>? _inAppSub;
  RealtimeChannel? _notifChannel;

  @override
  void initState() {
    super.initState();
    _load();
    _inAppSub = InAppNotificationBus.instance.stream.listen(_onInAppEvent);
    _subscribeNotificationRealtime();
  }

  @override
  void dispose() {
    _inAppSub?.cancel();
    final ch = _notifChannel;
    _notifChannel = null;
    if (ch != null) {
      unawaited(Supabase.instance.client.removeChannel(ch));
    }
    super.dispose();
  }

  void _subscribeNotificationRealtime() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) return;

    _notifChannel = Supabase.instance.client
        .channel('home-app-notifications-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'app_notifications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'recipient_id',
            value: uid,
          ),
          callback: (payload) {
            final row = payload.newRecord;
            final type = (row['event_type'] ?? '').toString();
            final title = (row['title'] ?? 'Уведомление').toString();
            final body = (row['body'] ?? '').toString();
            final pushPayload = pushPayloadFromNotificationData(row['data']);
            InAppNotificationBus.instance.emit(
              InAppNotificationEvent(
                type: type,
                title: title,
                body: body,
                payload: pushPayload,
              ),
            );
          },
        )
        .subscribe();
  }

  Future<void> _onInAppEvent(InAppNotificationEvent event) async {
    // Visual toast is handled globally by [InAppToastHost].
    await _refreshUnreadBadge();
  }

  Future<void> _refreshUnreadBadge() async {
    try {
      final count = await _notificationsApi.unreadCount();
      if (!mounted) return;
      setState(() => _unreadNotificationCount = count);
    } catch (_) {}
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final results = await Future.wait<Object?>([
        _service.load(),
        _notificationsApi.unreadCount(),
      ]);
      if (!mounted) return;
      setState(() {
        _data = results[0] as HomeDashboardData;
        _unreadNotificationCount = results[1] as int;
      });
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
    if (!data.isScheduleForToday && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loading) _load();
      });
    }

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: HomeHeader(
            profile: data.profile,
            currentDate: data.scheduleDate,
            notificationCount: _unreadNotificationCount,
            onNotificationsTap: () async {
              await showNotificationCenterSheet(context);
              if (!mounted) return;
              final count = await _notificationsApi.unreadCount();
              if (!mounted) return;
              setState(() => _unreadNotificationCount = count);
            },
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
            child: TodaySummaryCard(
              data: data,
              onTap: () => MainTabScope.switchToTab(context, MainTab.schedule),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _AnimatedEntry(
            delay: const Duration(milliseconds: 120),
            child: _AssignmentsSection(
              data: data,
              hiddenAssignmentIds: _hiddenDoneAssignmentIds,
              markingDoneAssignmentIds: _markingDoneAssignmentIds,
              onOpen: () => context.push('/my-diary'),
              onAssignmentTap: _showAssignmentDetails,
              onAssignmentDoneTap: _markAssignmentDone,
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

  Future<void> _markAssignmentDone(HomeAssignmentPreview item) async {
    final assignmentId = item.assignment.id;
    if (assignmentId.isEmpty ||
        _markingDoneAssignmentIds.contains(assignmentId) ||
        item.isDone) {
      return;
    }

    final confirmed = await _confirmAssignmentDone(item);
    if (confirmed != true || !mounted) return;

    setState(() {
      _hiddenDoneAssignmentIds.add(assignmentId);
      _markingDoneAssignmentIds.add(assignmentId);
    });

    try {
      await _service.setAssignmentDone(
        assignmentId: assignmentId,
        done: true,
      );
      if (!mounted) return;
      setState(() => _markingDoneAssignmentIds.remove(assignmentId));
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Задание отмечено выполненным'),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: 'Отменить',
              onPressed: () => _undoAssignmentDone(item),
            ),
          ),
        );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hiddenDoneAssignmentIds.remove(assignmentId);
        _markingDoneAssignmentIds.remove(assignmentId);
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Не удалось отметить задание. Попробуйте ещё раз.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  Future<void> _undoAssignmentDone(HomeAssignmentPreview item) async {
    final assignmentId = item.assignment.id;
    if (assignmentId.isEmpty) return;

    setState(() {
      _hiddenDoneAssignmentIds.remove(assignmentId);
      _markingDoneAssignmentIds.add(assignmentId);
    });

    try {
      await _service.setAssignmentDone(
        assignmentId: assignmentId,
        done: false,
      );
    } finally {
      if (!mounted) return;
      setState(() => _markingDoneAssignmentIds.remove(assignmentId));
      await _load();
    }
  }

  Future<bool?> _confirmAssignmentDone(HomeAssignmentPreview item) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final assignment = item.assignment;
    final sheetColor = isDark ? const Color(0xFF182331) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final bodyColor = titleColor.withValues(alpha: isDark ? 0.74 : 0.64);
    final accent = const Color(0xFF2F9D84);

    return showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      backgroundColor: sheetColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: isDark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        color: Color(0xFF2F9D84),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Отметить выполненным?',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: titleColor,
                          fontWeight: FontWeight.w900,
                          height: 1.12,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  assignment.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w800,
                    height: 1.22,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Задание исчезнет из ближайших на главной и будет отмечено выполненным в дневнике.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: bodyColor,
                    height: 1.38,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(sheetContext).pop(false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: titleColor,
                          side: BorderSide(
                            color: titleColor.withValues(alpha: 0.22),
                          ),
                        ),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(sheetContext).pop(true),
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('Выполнено'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
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
}

class _AssignmentsSection extends StatelessWidget {
  final HomeDashboardData data;
  final Set<String> hiddenAssignmentIds;
  final Set<String> markingDoneAssignmentIds;
  final VoidCallback onOpen;
  final ValueChanged<HomeAssignmentPreview> onAssignmentTap;
  final ValueChanged<HomeAssignmentPreview> onAssignmentDoneTap;

  const _AssignmentsSection({
    required this.data,
    required this.hiddenAssignmentIds,
    required this.markingDoneAssignmentIds,
    required this.onOpen,
    required this.onAssignmentTap,
    required this.onAssignmentDoneTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final assignments = data.assignments
        .where((item) => !hiddenAssignmentIds.contains(item.assignment.id))
        .take(4)
        .toList();
    final foreground = isDark ? Colors.white : const Color(0xFF1F2937);
    final mutedForeground = foreground.withValues(alpha: isDark ? 0.76 : 0.66);
    final accent = isDark ? const Color(0xFFF3C774) : const Color(0xFFB58B3B);
    final subtitle = assignments.isEmpty
        ? 'Здесь появятся ближайшие дедлайны'
        : '${data.assignmentsCount} ${_assignmentWord(data.assignmentsCount)} в списке';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
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
                    .withValues(alpha: isDark ? 0.24 : 0.28),
                blurRadius: 18,
                offset: const Offset(0, 9),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Stack(
              children: [
                Positioned(
                  right: -28,
                  top: -34,
                  child: _AssignmentsGlow(
                    size: 104,
                    color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.24),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: onOpen,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.white
                                    .withValues(alpha: isDark ? 0.15 : 0.58),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child:
                                  Icon(Icons.task_alt_rounded, color: accent),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Ближайшие задания',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      color: foreground,
                                      fontWeight: FontWeight.w900,
                                      height: 1.1,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: mutedForeground,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (assignments.isEmpty)
                      const _EmptyState(
                        title: 'Пока нет ближайших заданий',
                        text:
                            'Если староста добавит задание в чат, оно появится здесь',
                        icon: Icons.check_circle_outline_rounded,
                      )
                    else
                      ...assignments.map(
                        (item) => Padding(
                          padding: EdgeInsets.only(
                            bottom: item == assignments.last ? 0 : 10,
                          ),
                          child: TaskPreviewCard(
                            item: item,
                            onTap: () => onAssignmentTap(item),
                            onDoneTap: () => onAssignmentDoneTap(item),
                            markingDone: markingDoneAssignmentIds
                                .contains(item.assignment.id),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _assignmentWord(int count) {
    if (count % 10 == 1 && count % 100 != 11) return 'задание';
    if ([2, 3, 4].contains(count % 10) && ![12, 13, 14].contains(count % 100)) {
      return 'задания';
    }
    return 'заданий';
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

class _AssignmentsGlow extends StatelessWidget {
  final double size;
  final Color color;

  const _AssignmentsGlow({
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
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
