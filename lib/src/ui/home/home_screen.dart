import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:student_ui/student_ui.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/group_action_labels.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/navigation/group_action_deeplink.dart';
import 'package:student_platform/src/ui/navigation/main_tab_scope.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final HomeDashboardService _service = HomeDashboardService();
  final HomePromoService _promoService = HomePromoService();
  final AppNotificationsApi _notificationsApi = AppNotificationsApi();

  HomeDashboardData? _data;
  HomePromoLoadResult _promo = const HomePromoLoadResult(isDemoFallback: true);
  Object? _error;
  bool _loading = true;
  int _unreadNotificationCount = 0;
  int _promoLoadGeneration = 0;
  String? _recordedImpressionId;
  final Set<String> _hiddenDoneAssignmentIds = {};
  final Set<String> _markingDoneAssignmentIds = {};
  StreamSubscription<InAppNotificationEvent>? _inAppSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _inAppSub = InAppNotificationBus.instance.stream.listen(_onInAppEvent);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inAppSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_load());
    }
  }

  Future<void> _onInAppEvent(InAppNotificationEvent event) async {
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
    final hadData = _data != null;
    if (mounted && !hadData) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    // Cache-first: paint previously saved news image bytes ASAP.
    unawaited(_paintCachedNews());

    final promoGeneration = ++_promoLoadGeneration;
    // Await cache paint before remote so a slow cache cannot overwrite fresher data.
    await _paintCachedPromo(promoGeneration);

    try {
      final results = await Future.wait<Object?>([
        _service.load(),
        _notificationsApi.unreadCount(),
        _loadPromoSafe(),
      ]);
      if (!mounted || promoGeneration != _promoLoadGeneration) return;
      final next = results[0] as HomeDashboardData;
      final promo = results[2] as HomePromoLoadResult;
      setState(() {
        _data = _mergeDashboardNewsImages(_data, next);
        _unreadNotificationCount = results[1] as int;
        _promo = promo;
        _error = null;
      });
      _maybeRecordPromoImpression(promo);
    } catch (error) {
      if (!mounted) return;
      // Keep last good dashboard (and images) on refresh failure.
      if (!hadData) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<HomePromoLoadResult> _loadPromoSafe() async {
    try {
      return await _promoService.load();
    } catch (error) {
      debugPrint('[home] promo load failed: $error');
      // Hard errors: last-good cache only. Demo only when RPC is truly missing
      // (handled inside service) — never treat permission/DB failures as demo.
      final cached = await _promoService.loadCached();
      if (cached.card != null) {
        return HomePromoLoadResult(card: cached.card, loadError: true);
      }
      return const HomePromoLoadResult(loadError: true, intentionallyEmpty: true);
    }
  }

  Future<void> _paintCachedPromo(int generation) async {
    try {
      final cached = await _promoService.loadCached();
      if (!mounted ||
          generation != _promoLoadGeneration ||
          cached.card == null) {
        return;
      }
      setState(() => _promo = cached);
    } catch (_) {}
  }

  Future<void> _paintCachedNews() async {
    try {
      final cached = await _service.loadCachedNews();
      if (!mounted || cached.isEmpty || _data == null) return;
      setState(() {
        _data = _mergeDashboardNewsImages(
          _data,
          HomeDashboardData(
            profile: _data!.profile,
            scheduleDate: _data!.scheduleDate,
            todayLessons: _data!.todayLessons,
            assignments: _data!.assignments,
            news: cached,
            readNotificationIds: _data!.readNotificationIds,
            unreadMessagesCount: _data!.unreadMessagesCount,
            warning: _data!.warning,
            groupActions: _data!.groupActions,
          ),
        );
      });
    } catch (_) {}
  }

  HomeDashboardData _mergeDashboardNewsImages(
    HomeDashboardData? previous,
    HomeDashboardData next,
  ) {
    if (previous == null) return next;
    final prevById = {for (final item in previous.news) item.id: item};
    final news = [
      for (final item in next.news)
        if (item.imageBytes == null &&
            prevById[item.id]?.imageBytes != null &&
            prevById[item.id]!.imageCacheKey?.id == item.imageCacheKey?.id)
          item.copyWith(imageBytes: prevById[item.id]!.imageBytes)
        else
          item,
    ];
    return HomeDashboardData(
      profile: next.profile,
      scheduleDate: next.scheduleDate,
      todayLessons: next.todayLessons,
      assignments: next.assignments,
      news: news,
      readNotificationIds: next.readNotificationIds,
      unreadMessagesCount: next.unreadMessagesCount,
      warning: next.warning,
      groupActions: next.groupActions,
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (_loading && data == null) {
      return const _HomeStatusSurface(child: _LoadingDashboard());
    }
    if (_error != null && data == null) {
      return _HomeStatusSurface(
        child: _ErrorDashboard(
          onRetry: _load,
          message:
              'Не удалось загрузить главную. Потяните вниз или попробуйте ещё раз.',
        ),
      );
    }
    if (data == null) return const SizedBox.shrink();

    if (!data.isScheduleForToday && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loading) _load();
      });
    }

    return Column(
      children: [
        Expanded(
          child: StudentHomeView(
            data: _toPresentationData(data),
            notificationCount: _unreadNotificationCount,
            onRefresh: _load,
            onNotificationsTap: _openNotifications,
            onNewsTap: (index) => _showNewsFeed(data.news, index),
            onSummaryTap: () => MainTabScope.switchToTab(
              context,
              MainTab.schedule,
            ),
            onGroupActionTap: _openGroupAction,
            onAssignmentsOpen: () => context.push('/my-diary'),
            onAssignmentTap: (item) {
              final source = _findAssignment(item.id);
              if (source != null) _showAssignmentDetails(source);
            },
            onAssignmentDoneTap: (item) {
              final source = _findAssignment(item.id);
              if (source != null) _markAssignmentDone(source);
            },
            homePromo: _promo.hidePromoStrip
                ? null
                : (_promo.isDemoFallback ? null : _promo.payload),
            homePromoIsDemo: _promo.showDemoBadge,
            hideHomePromo: _promo.hidePromoStrip,
            onHelpTap: _onHomePromoTap,
            onHomePromoDismiss: _onHomePromoDismiss,
            hiddenAssignmentIds: _hiddenDoneAssignmentIds,
            markingDoneAssignmentIds: _markingDoneAssignmentIds,
          ),
        ),
      ],
    );
  }

  void _openGroupAction(StudentHomeGroupAction action) {
    final source = _findGroupAction(action.id);
    if (source == null) return;
    openGroupActionDeeplink(
      context,
      GroupActionDeeplinkArgs.fromDeadline(
        eventType: source.eventType,
        entityId: source.entityId,
        chatId: source.chatId,
        cardMessageId: source.cardMessageId,
        teamId: source.teamId,
      ),
    );
  }

  HomeGroupActionPreview? _findGroupAction(String id) {
    final data = _data;
    if (data == null) return null;
    for (final action in data.groupActions) {
      if ('${action.eventType}|${action.entityId}' == id) return action;
    }
    return null;
  }

  StudentHomeData _toPresentationData(HomeDashboardData data) {
    return StudentHomeData(
      profile: StudentHomeProfile(
        name: data.profile.displayName,
        groupName: data.profile.groupName,
      ),
      currentDate: data.scheduleDate,
      lessons: [
        for (final lesson in data.remainingLessons)
          StudentHomeLesson(
            subject: lesson.subject,
            start: lesson.start,
            pairNumber: lesson.pairNum,
            room: lesson.room ?? '',
            teacher: lesson.teacher ?? '',
          ),
      ],
      assignments: [
        for (final item in data.assignments)
          StudentHomeAssignment(
            id: item.assignment.id,
            title: item.assignment.title,
            subject: item.teamName,
            deadline: _deadlineText(item),
            status: _assignmentStatus(item),
            isDone: item.isDone,
            dueAt: item.dueAt,
          ),
      ],
      news: _presentationNews(data.news),
      groupActions: [
        for (final action in data.groupActions)
          StudentHomeGroupAction(
            id: '${action.eventType}|${action.entityId}',
            title: action.title,
            kindLabel: action.kindLabel,
            deadlineText: _fmtActionDate(action.occursAt),
            teamName: action.teamName,
            myPickText: action.myPickText,
            occursAt: action.occursAt,
            isTopic: action.isTopic,
            isCollection: action.isCollection,
            followUpTitle:
                action.isTopic && (action.myPickText ?? '').trim().isNotEmpty
                    ? topicFollowUpTitle(action.myPickText!)
                    : null,
            statusLine: action.isCollection
                ? collectionHomeStatusLine(action.myPickText)
                : (action.isTopic && (action.myPickText ?? '').trim().isNotEmpty
                    ? 'Тема занята'
                    : null),
            isPendingReview: false,
            isCompleted: action.isCollection &&
                collectionMyPickIsDoneForParticipant(action.myPickText),
            // Delete is available in chat/schedule details, not on Home cards.
            canDelete: false,
          ),
      ],
      totalLessonsToday: data.totalLessonsToday,
      assignmentsCount: data.assignmentsCount,
      lessonsFinishedForToday: data.lessonsFinishedForToday,
    );
  }

  String _fmtActionDate(DateTime dt) {
    return DateFormat('d MMM, HH:mm', 'ru').format(dt.toLocal());
  }

  List<StudentHomeNews> _presentationNews(List<HomeNewsItem> news) {
    return [
      for (final item in news)
        StudentHomeNews(
          id: item.id,
          title: item.title,
          subtitle: item.subtitle,
          body: item.body,
          icon: item.icon,
          gradientColors: item.gradientColors,
          variant: item.variant,
          imageBytes: item.imageBytes,
          imageFocus: item.imageFocus,
          overlayDarken: item.overlayDarken,
          publishedAt: item.publishedAt,
        ),
    ];
  }

  HomeAssignmentPreview? _findAssignment(String id) {
    for (final item in _data?.assignments ?? const <HomeAssignmentPreview>[]) {
      if (item.assignment.id == id) return item;
    }
    return null;
  }

  StudentHomeAssignmentStatus _assignmentStatus(HomeAssignmentPreview item) {
    if (item.isDone) return StudentHomeAssignmentStatus.done;
    if (item.assignment.status == 'in_progress') {
      return StudentHomeAssignmentStatus.inProgress;
    }
    return StudentHomeAssignmentStatus.notStarted;
  }

  Future<void> _openNotifications() async {
    await showNotificationCenterSheet(context);
    if (!mounted) return;
    final count = await _notificationsApi.unreadCount();
    if (!mounted) return;
    setState(() => _unreadNotificationCount = count);
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
    final sheetColor = isDark ? const Color(0xFF182331) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final bodyColor = titleColor.withValues(alpha: isDark ? 0.74 : 0.64);
    const accent = Color(0xFF2F9D84);

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
                        color: accent,
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
                  item.assignment.title,
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
    final byId = {for (final item in news) item.id: item};
    final presentation = _presentationNews(news);
    final safeIndex = initialIndex.clamp(0, presentation.length - 1);
    _service.markNewsSeen(presentation[safeIndex].id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) => StudentNewsStorySheet(
        news: presentation,
        initialIndex: safeIndex,
        onPageChanged: (id) => _service.markNewsSeen(id),
        onClosed: (id) => _service.markNewsSeen(id, closed: true),
        resolveImage: (item) async {
          final source = byId[item.id];
          if (source == null) return item.imageBytes;
          return _service.resolveNewsImageBytes(source);
        },
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

  void _maybeRecordPromoImpression(HomePromoLoadResult promo) {
    final id = promo.card?.id;
    if (id == null ||
        promo.isDemoFallback ||
        promo.hidePromoStrip ||
        promo.loadError) {
      return;
    }
    if (_recordedImpressionId == id) return;
    _recordedImpressionId = id;
    unawaited(_promoService.recordEvent(id, 'impression'));
  }

  Future<void> _onHomePromoTap() async {
    final managedId = _promo.card?.id;
    if (managedId != null &&
        !_promo.isDemoFallback &&
        !_promo.hidePromoStrip) {
      await _promoService.recordEvent(managedId, 'click');
    }

    final payload = _promo.payload;
    final route = payload.ctaRoute?.trim();
    if (route != null && route.isNotEmpty) {
      if (route == '/help' ||
          route == '/info' ||
          route == '/my-diary' ||
          route == '/diary') {
        if (route == '/my-diary' || route == '/diary') {
          context.push('/my-diary');
          return;
        }
        _showHelpDetails();
        return;
      }
      try {
        context.push(route);
        return;
      } catch (_) {
        // Fall through to URL / sheet.
      }
    }
    final url = payload.ctaUrl?.trim();
    if (url != null && url.isNotEmpty) {
      final uri = Uri.tryParse(url);
      if (uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return;
      }
    }
    _showHelpDetails();
  }

  Future<void> _onHomePromoDismiss() async {
    final id = _promo.card?.id;
    if (id == null || _promo.isDemoFallback) {
      setState(() {
        _promo = const HomePromoLoadResult(intentionallyEmpty: true);
      });
      return;
    }
    try {
      await _promoService.dismiss(id);
      if (!mounted) return;
      // Optimistic hide; successful empty must not resurrect demo (14.1).
      setState(() {
        _promo = const HomePromoLoadResult(intentionallyEmpty: true);
      });
      final refreshed = await _loadPromoSafe();
      if (!mounted) return;
      setState(() => _promo = refreshed);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось скрыть карточку.')),
      );
    }
  }

  void _showHelpDetails() {
    _showDetailsSheet(
      title: _promo.payload.title,
      icon: _promo.payload.iconData,
      accent: const Color(0xFF8A72D8),
      children: [
        Text(
          _promo.payload.subtitle,
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
    if (item.assignment.status == 'in_progress') return 'в процессе';
    return 'не начато';
  }
}

class _HomeStatusSurface extends StatelessWidget {
  const _HomeStatusSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF101820) : const Color(0xFFFAF8FC),
      body: SafeArea(child: child),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              '$label:',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.56),
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
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

class _LoadingDashboard extends StatelessWidget {
  const _LoadingDashboard();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: const [
        _SkeletonLine(width: 180, height: 28),
        SizedBox(height: 10),
        _SkeletonLine(width: 240, height: 18),
        SizedBox(height: 18),
        _SkeletonBlock(height: 128, radius: 26),
        SizedBox(height: 22),
        _SkeletonBlock(height: 190, radius: 24),
        SizedBox(height: 14),
        _SkeletonBlock(height: 220, radius: 24),
      ],
    );
  }
}

class _ErrorDashboard extends StatelessWidget {
  const _ErrorDashboard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        SizedBox(height: MediaQuery.sizeOf(context).height * 0.18),
        Icon(
          Icons.cloud_off_rounded,
          size: 56,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 18),
        const Text(
          'Что-то пошло не так',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
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
  const _SkeletonBlock({required this.height, required this.radius});

  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return _SkeletonBase(
      radius: radius,
      child: SizedBox(height: height, width: double.infinity),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return _SkeletonBase(
      radius: height / 2,
      child: SizedBox(width: width, height: height),
    );
  }
}

class _SkeletonBase extends StatelessWidget {
  const _SkeletonBase({required this.child, required this.radius});

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}
