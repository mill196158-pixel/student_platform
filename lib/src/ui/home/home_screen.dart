import 'dart:async';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kReleaseMode, ValueListenable;
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:student_ui/student_ui.dart';

import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/ui/content/content_nav_executor.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/home_content_coordinator.dart';
import 'package:student_platform/src/ui/home/home_content_verified_loader.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/group_action_labels.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/navigation/group_action_deeplink.dart';
import 'package:student_platform/src/ui/navigation/main_tab_scope.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:student_platform/src/ui/profile/profile_avatar_image.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      this.dashboardService,
      this.promoService,
      this.contentMedia,
      this.activeListenable,
      this.notificationsApi,
      this.cachedReader,
      this.onlineBarrier,
      this.homeContent,
      this.homeContentCapabilities});
  final HomeDashboardService? dashboardService;
  final HomePromoService? promoService;
  final ContentMediaService? contentMedia;
  final AppNotificationsApi? notificationsApi;

  /// Only passed after a separately verified cache-only admission.
  final CachedHomeScheduleReader? cachedReader;
  final OnlineSideEffectBarrier? onlineBarrier;
  final HomeContentCoordinator? homeContent;
  final SessionCapabilities? homeContentCapabilities;
  final ValueListenable<bool>? activeListenable;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late HomeDashboardService _service;
  AuthSessionScope? _authScope;
  bool _serviceInitialized = false;
  bool _ownsService = false;
  late final HomePromoService _promoService =
      widget.promoService ?? HomePromoService();
  late final ContentMediaService _contentMedia =
      widget.contentMedia ?? ContentMediaService(persistBytes: true);
  late final AppNotificationsApi _notificationsApi =
      widget.notificationsApi ?? AppNotificationsApi();

  HomeDashboardData? _data;
  HomePromoLoadResult _promo =
      const HomePromoLoadResult(intentionallyEmpty: true);
  String? _avatarPrecacheKey;
  Object? _error;
  bool _loading = true;
  int _unreadNotificationCount = 0;
  int _promoLoadGeneration = 0;
  int _modeRevision = 0;
  int _promoMediaGeneration = 0;
  final Set<String> _recordedImpressionIds = {};
  final Map<String, GlobalKey> _promoKeys = {};
  bool _impressionFramePending = false;
  final Map<String, String> _promoAssetIdentities = {};
  final Map<String, Uint8List> _promoImageBytes = {};
  final Map<String, Uint8List> _promoIconBytes = {};
  final Map<String, ContentImageRenderState> _promoImageStates = {};
  final Set<String> _hiddenDoneAssignmentIds = {};
  final Set<String> _markingDoneAssignmentIds = {};
  StreamSubscription<InAppNotificationEvent>? _inAppSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.activeListenable?.addListener(_queuePromoImpressions);
    widget.homeContent?.addListener(_onContentAccessChanged);
    if (widget.cachedReader == null) {
      _inAppSub = InAppNotificationBus.instance.stream.listen(_onInAppEvent);
    }
  }

  void _onContentAccessChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = AuthSessionScopeHost.maybeOf(context);
    if (_serviceInitialized && identical(source, _authScope)) return;
    if (_serviceInitialized) {
      _authScope?.removeListener(_onAuthScopeChanged);
      if (_ownsService) _service.dispose();
      _data = null;
      _loadInFlight = null;
      _loadUserId = null;
      _loadAuthScope = null;
      _promoLoadGeneration++;
    }
    _authScope = source;
    _authScope?.addListener(_onAuthScopeChanged);
    _ownsService = widget.dashboardService == null;
    _service =
        widget.dashboardService ?? HomeDashboardService(sessionScope: source);
    _serviceInitialized = true;
    unawaited(_load());
  }

  void _onAuthScopeChanged() {
    if (!mounted) return;
    final scope = _authScope?.capture();
    if (_authScope != null && scope == null) {
      setState(() {
        _data = null;
        _error = null;
        _loading = true;
        _loadUserId = null;
        _loadAuthScope = null;
        _loadInFlight = null;
        _promoLoadGeneration++;
      });
      return;
    }
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.homeContent, widget.homeContent)) {
      oldWidget.homeContent?.removeListener(_onContentAccessChanged);
      widget.homeContent?.addListener(_onContentAccessChanged);
    }
    final modeChanged = !identical(oldWidget.cachedReader, widget.cachedReader);
    final serviceChanged =
        !identical(oldWidget.dashboardService, widget.dashboardService);
    if (_serviceInitialized &&
        !modeChanged &&
        !serviceChanged &&
        !identical(oldWidget.onlineBarrier, widget.onlineBarrier) &&
        widget.cachedReader == null &&
        widget.onlineBarrier != null) {
      unawaited(_service.prewarmSchedule(widget.onlineBarrier!));
    }
    if (!_serviceInitialized || (!modeChanged && !serviceChanged)) return;
    if (modeChanged) {
      _modeRevision++;
      _hiddenDoneAssignmentIds.clear();
      _markingDoneAssignmentIds.clear();
      _inAppSub?.cancel();
      _inAppSub = widget.cachedReader == null
          ? InAppNotificationBus.instance.stream.listen(_onInAppEvent)
          : null;
      _promoMediaGeneration++;
      _promo = const HomePromoLoadResult(intentionallyEmpty: true);
      _unreadNotificationCount = 0;
      _promoImageBytes.clear();
      _promoIconBytes.clear();
      _promoImageStates.clear();
      _promoAssetIdentities.clear();
      _promoKeys.clear();
      _recordedImpressionIds.clear();
    }
    if (serviceChanged) {
      if (_ownsService) _service.dispose();
      _ownsService = widget.dashboardService == null;
      _service = widget.dashboardService ??
          HomeDashboardService(sessionScope: _authScope);
    }
    _data = null;
    _error = null;
    _loading = true;
    _loadInFlight = null;
    _loadUserId = null;
    _loadAuthScope = null;
    _promoLoadGeneration++;
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.activeListenable?.removeListener(_queuePromoImpressions);
    widget.homeContent?.removeListener(_onContentAccessChanged);
    _authScope?.removeListener(_onAuthScopeChanged);
    if (_serviceInitialized && _ownsService) _service.dispose();
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
    final modeRevision = _modeRevision;
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision;
    if (!stillOnline()) return;
    if (widget.cachedReader != null) return;
    try {
      final count = await _notificationsApi.unreadCount();
      if (!stillOnline()) return;
      setState(() => _unreadNotificationCount = count);
    } catch (_) {}
  }

  Future<void>? _loadInFlight;
  String? _loadUserId;
  AuthOperationScope? _loadAuthScope;
  Future<void> _load() {
    final userId = _service.currentUserId;
    final operationScope = _authScope?.capture();
    if (_loadInFlight != null &&
        _loadUserId == userId &&
        _loadAuthScope == operationScope) return _loadInFlight!;
    if (_loadUserId != userId) {
      _data = null;
      _error = null;
      _avatarPrecacheKey = null;
      _promo = const HomePromoLoadResult(intentionallyEmpty: true);
      ++_promoMediaGeneration;
      _promoAssetIdentities.clear();
      _promoImageBytes.clear();
      _promoIconBytes.clear();
      _promoImageStates.clear();
      _recordedImpressionIds.clear();
      _promoKeys.clear();
    }
    _loadUserId = userId;
    _loadAuthScope = operationScope;
    final work = _loadDashboard();
    _loadInFlight = work;
    void release() {
      if (identical(_loadInFlight, work)) _loadInFlight = null;
    }

    unawaited(work.then<void>((_) => release(),
        onError: (Object _, StackTrace __) => release()));
    return work;
  }

  Future<void> _loadDashboard() async {
    final reader = widget.cachedReader;
    if (reader != null) {
      try {
        final snapshot = await reader.readDashboard();
        final content = widget.homeContent;
        final caps = widget.homeContentCapabilities;
        Future<HomeContentSnapshot?> readOptional(String section) async {
          if (content == null || caps == null) return null;
          try {
            return await content.read(section, caps);
          } catch (error) {
            debugPrint(
                '[home-cache] $section unavailable: ${error.runtimeType}');
            return null;
          }
        }

        final savedNews = await readOptional('news');
        final savedPromo = await readOptional('promo');
        if (!mounted || widget.cachedReader != reader || !reader.canRead)
          return;
        final news = <HomeNewsItem>[];
        for (final row in savedNews?.rows ?? <Map<String, dynamic>>[]) {
          try {
            final item = mapPublishedNews(row);
            final key = row['_offline_image'];
            news.add(item.copyWith(
                imageBytes: key is String ? savedNews!.images[key] : null));
          } catch (_) {
            /* A malformed optional card cannot hide the dashboard. */
          }
        }
        final promos = <ManagedContentCard>[];
        for (final row in savedPromo?.rows ?? <Map<String, dynamic>>[]) {
          final card = ManagedContentCard.tryParseHomePromo(row);
          if (card == null) continue;
          final imageKey = row['_offline_image'];
          final iconKey = row['_offline_icon'];
          final image =
              imageKey is String ? savedPromo!.images[imageKey] : null;
          final icon = iconKey is String ? savedPromo!.images[iconKey] : null;
          if (image != null) {
            _promoAssetIdentities[card.id] = _promoIdentity(card);
            _promoImageBytes[card.id] = image;
            _promoImageStates[card.id] = ContentImageReady(image);
          }
          if (icon != null) _promoIconBytes[card.id] = icon;
          promos.add(card);
        }
        setState(() {
          _data = HomeDashboardData(
              profile: snapshot.profile,
              scheduleDate: snapshot.scheduleDate,
              todayLessons: snapshot.todayLessons,
              assignments: snapshot.assignments,
              news: news,
              scheduleStatus: snapshot.scheduleStatus,
              assignmentsStatus: snapshot.assignmentsStatus,
              readNotificationIds: snapshot.readNotificationIds,
              unreadMessagesCount: snapshot.unreadMessagesCount,
              warning: snapshot.warning,
              groupActions: snapshot.groupActions);
          _promo = HomePromoLoadResult(
              cards: promos, intentionallyEmpty: promos.isEmpty);
          _loading = false;
          _error = null;
        });
      } catch (error) {
        if (!mounted || widget.cachedReader != reader) return;
        setState(() {
          _data = null;
          _loading = false;
          _error = error;
        });
      }
      return;
    }
    final firstContentClock = Stopwatch()..start();
    final onlineBarrier = widget.onlineBarrier;
    if (onlineBarrier != null && onlineBarrier.isOpen) {
      unawaited(_service.prewarmSchedule(onlineBarrier));
      final content = widget.homeContent;
      if (content != null) {
        for (final section in HomeContentSection.values) {
          unawaited(
              content.warm(section, onlineBarrier).catchError((Object _) {}));
        }
      }
    }
    var reportedFirstContent = false;
    final userId = _service.currentUserId;
    final hadData = _data != null;
    if (mounted && !hadData) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final promoGeneration = ++_promoLoadGeneration;
    // Cache-first, scoped to this account and refresh attempt.
    unawaited(_paintCachedNews(promoGeneration, userId));
    // Promo metadata/media must not wait for schedule, news or badge queries.
    unawaited(_refreshPromo(promoGeneration));
    unawaited(_refreshUnreadBadge());
    try {
      final next = await _service
          .load(
              previous: _data,
              onUpdate: (partial) {
                if (!mounted ||
                    promoGeneration != _promoLoadGeneration ||
                    _service.currentUserId != userId) return;
                if (!reportedFirstContent &&
                    (!kReleaseMode ||
                        const bool.fromEnvironment('STARTUP_TRACE'))) {
                  reportedFirstContent = true;
                  debugPrint(
                      '[home-perf] first partial data ${firstContentClock.elapsedMilliseconds}ms');
                }
                setState(() {
                  _data = _mergeDashboardNewsImages(_data, partial);
                  _error = null;
                });
                _warmProfileAvatar(partial.profile);
              })
          .timeout(const Duration(seconds: 18));
      if (!mounted ||
          promoGeneration != _promoLoadGeneration ||
          _service.currentUserId != userId) return;
      setState(() {
        _data = _mergeDashboardNewsImages(_data, next);
        _error = null;
      });
    } catch (error) {
      if (error is HomeLoadCancelled) return;
      if (!mounted ||
          _service.currentUserId != userId ||
          promoGeneration != _promoLoadGeneration) return;
      if (error is TimeoutException) {
        ++_promoLoadGeneration; // Ignore late updates from this attempt.
        setState(() {
          _loading = false;
          _error = error;
        });
      }
      // Keep last good dashboard (and images) on refresh failure.
      if (!hadData) setState(() => _error = error);
    } finally {
      if (mounted && promoGeneration == _promoLoadGeneration)
        setState(() => _loading = false);
    }
  }

  Future<void> _refreshPromo(int generation) async {
    final userId = _service.currentUserId;
    await _paintCachedPromo(generation);
    if (!mounted ||
        widget.cachedReader != null ||
        generation != _promoLoadGeneration ||
        userId != _service.currentUserId) return;
    final promo = await _loadPromoSafe();
    if (!mounted ||
        generation != _promoLoadGeneration ||
        userId != _service.currentUserId) return;
    setState(() => _promo = promo);
    await _hydratePromoMedia(promo);
  }

  Future<HomePromoLoadResult> _loadPromoSafe() async {
    try {
      return await _promoService.load().timeout(const Duration(seconds: 12));
    } catch (error) {
      debugPrint('[home] promo load failed: $error');
      // Hard errors: last-good cache only. Demo only when RPC is truly missing
      // (handled inside service) — never treat permission/DB failures as demo.
      final cached = await _promoService.loadCached();
      if (cached.cards.isNotEmpty) {
        return HomePromoLoadResult(cards: cached.cards, loadError: true);
      }
      return const HomePromoLoadResult(
          loadError: true, intentionallyEmpty: true);
    }
  }

  Future<void> _paintCachedPromo(int generation) async {
    final userId = _service.currentUserId;
    try {
      final cached = await _promoService.loadCached();
      if (!mounted ||
          generation != _promoLoadGeneration ||
          userId != _service.currentUserId ||
          (cached.card == null && !cached.intentionallyEmpty)) {
        return;
      }
      setState(() => _promo = cached);
      unawaited(_hydratePromoMedia(cached));
    } catch (_) {}
  }

  void _warmProfileAvatar(HomeUserProfile profile) {
    final uid = _service.currentUserId;
    if (!mounted || uid == null || profile.id != uid) return;
    final key = '$uid|${profile.avatarUrl}';
    if (_avatarPrecacheKey == key) return;
    final provider = profileAvatarImage(uid, profile.avatarUrl);
    if (provider == null) return;
    _avatarPrecacheKey = key;
    unawaited(precacheImage(provider, context, onError: (_, __) {
      if (_avatarPrecacheKey == key) _avatarPrecacheKey = null;
    }));
  }

  Future<void> _paintCachedNews(int generation, String? userId) async {
    try {
      final cached = await _service.loadCachedNews();
      if (!mounted ||
          generation != _promoLoadGeneration ||
          userId != _service.currentUserId ||
          cached.isEmpty ||
          _data == null) return;
      setState(() {
        _data = _mergeDashboardNewsImages(
          _data,
          HomeDashboardData(
            scheduleStatus: _data!.scheduleStatus,
            assignmentsStatus: _data!.assignmentsStatus,
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
      scheduleStatus: next.scheduleStatus,
      assignmentsStatus: next.assignmentsStatus,
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
    _queuePromoImpressions();

    if (!data.isScheduleForToday && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_loading) _load();
      });
    }

    return Column(
      children: [
        if (widget.cachedReader != null)
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Без сети · новости и объявления могут быть недоступны',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
        if (_error != null)
          TextButton(
              onPressed: _load,
              child: const Text('Не всё удалось обновить. Повторить')),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _queuePromoImpressions();
              return false;
            },
            child: StudentHomeView(
              data: _toPresentationData(data),
              notificationCount: _unreadNotificationCount,
              onRefresh: _load,
              onNotificationsTap:
                  widget.cachedReader == null ? _openNotifications : null,
              onNewsTap: (index) => _showNewsFeed(data.news, index),
              onSummaryTap: () => MainTabScope.switchToTab(
                context,
                MainTab.schedule,
              ),
              onGroupActionTap:
                  widget.cachedReader == null ? _openGroupAction : null,
              onAssignmentsOpen: widget.cachedReader == null
                  ? () => context.push('/my-diary')
                  : null,
              onAssignmentTap: widget.cachedReader != null
                  ? null
                  : (item) {
                      final source = _findAssignment(item.id);
                      if (source != null) _showAssignmentDetails(source);
                    },
              onAssignmentDoneTap: widget.cachedReader != null
                  ? null
                  : (item) {
                      final source = _findAssignment(item.id);
                      if (source != null) _markAssignmentDone(source);
                    },
              homePromo: _promo.hidePromoStrip || _promo.cards.length != 1
                  ? null
                  : (_promo.isDemoFallback ? null : _promo.payload),
              homePromoIsDemo: _promo.showDemoBadge && _promo.cards.length <= 1,
              hideHomePromo: _promoPlacements().isEmpty,
              homePromoPlacements: _promoPlacements(),
              // Placements carry per-card callbacks; these remain as single-slot fallbacks.
              onHelpTap: () => _onHomePromoTap(card: _promo.card),
              onHomePromoDismiss: _promo.card == null
                  ? null
                  : () => _onHomePromoDismiss(_promo.card!),
              hiddenAssignmentIds: _hiddenDoneAssignmentIds,
              markingDoneAssignmentIds: _markingDoneAssignmentIds,
            ),
          ),
        ),
      ],
    );
  }

  void _openGroupAction(StudentHomeGroupAction action) {
    if (widget.cachedReader != null) return;
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
      scheduleStatus: data.scheduleStatus,
      assignmentsStatus: data.assignmentsStatus,
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
      news: _presentationNews(
          widget.homeContent?.isDenied('news') == true ? const [] : data.news),
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
    final modeRevision = _modeRevision;
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision;
    if (!stillOnline()) return;
    if (widget.cachedReader != null) return;
    await showNotificationCenterSheet(context);
    if (!stillOnline()) return;
    final count = await _notificationsApi.unreadCount();
    if (!stillOnline()) return;
    setState(() => _unreadNotificationCount = count);
  }

  Future<void> _markAssignmentDone(HomeAssignmentPreview item) async {
    final modeRevision = _modeRevision;
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision;
    if (!stillOnline()) return;
    if (widget.cachedReader != null) return;
    final assignmentId = item.assignment.id;
    if (assignmentId.isEmpty ||
        _markingDoneAssignmentIds.contains(assignmentId) ||
        item.isDone) {
      return;
    }

    final confirmed = await _confirmAssignmentDone(item);
    if (confirmed != true || !stillOnline()) return;

    setState(() {
      _hiddenDoneAssignmentIds.add(assignmentId);
      _markingDoneAssignmentIds.add(assignmentId);
    });

    try {
      await _service.setAssignmentDone(
        assignmentId: assignmentId,
        done: true,
      );
      if (!stillOnline()) return;
      setState(() => _markingDoneAssignmentIds.remove(assignmentId));
      await _load();
      if (!stillOnline()) return;
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
      if (!stillOnline()) return;
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
    final modeRevision = _modeRevision;
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision;
    if (!stillOnline()) return;
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
      if (!stillOnline()) return;
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
    final reader = widget.cachedReader;
    final barrier = widget.onlineBarrier;
    final content = widget.homeContent;
    final scope = _authScope;
    final owner = scope?.capture();
    final active = ValueNotifier<bool>(true);
    final navigator = Navigator.of(context);
    ModalBottomSheetRoute<void>? sheetRoute;
    bool current() =>
        mounted &&
        identical(widget.cachedReader, reader) &&
        identical(widget.onlineBarrier, barrier) &&
        identical(widget.homeContent, content) &&
        (reader == null || reader.canRead) &&
        (barrier == null || barrier.isOpen) &&
        (scope == null || (owner != null && scope.isCurrent(owner))) &&
        content?.isDenied('news') != true;
    void check() {
      if (!current()) {
        active.value = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = sheetRoute;
          if (target != null && target.isActive && navigator.mounted) {
            navigator.removeRoute(target);
          }
        });
      }
    }

    void mark(String id, {bool closed = false}) {
      if (!current()) return;
      if (barrier == null) {
        unawaited(_service.markNewsSeen(id, closed: closed));
      } else {
        unawaited(barrier.run(() => _service.markNewsSeen(id, closed: closed)));
      }
    }

    final removeClose = barrier?.onClose(check);
    scope?.addListener(check);
    reader?.accessChanges.addListener(check);
    content?.addListener(check);
    if (reader == null) mark(presentation[safeIndex].id);
    sheetRoute = ModalBottomSheetRoute<void>(
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) {
        Widget sheet() => StudentNewsStorySheet(
              news: presentation,
              initialIndex: safeIndex,
              onPageChanged: reader == null ? (id) => mark(id) : null,
              onClosed: reader == null ? (id) => mark(id, closed: true) : null,
              // The legacy resolver uses internal timeouts and cannot prove
              // its underlying HTTP work has settled when a barrier drains.
              resolveImage: reader == null && barrier == null
                  ? (item) async {
                      if (!current()) return null;
                      final source = byId[item.id];
                      if (source == null) return item.imageBytes;
                      final bytes =
                          await _service.resolveNewsImageBytes(source);
                      return current() ? bytes : null;
                    }
                  : null,
            );
        final changes = <Listenable>[
          active,
          if (reader != null) reader.accessChanges,
          if (widget.homeContent != null) widget.homeContent!,
        ];
        if (changes.isEmpty) return sheet();
        return ListenableBuilder(
            listenable: Listenable.merge(changes),
            builder: (_, __) => active.value &&
                    current() &&
                    (reader == null || reader.canRead) &&
                    widget.homeContent?.isDenied('news') != true
                ? sheet()
                : const SizedBox.shrink());
      },
    );
    final route = navigator.push(sheetRoute);
    if (!current()) check();
    unawaited(route.whenComplete(() {
      removeClose?.call();
      scope?.removeListener(check);
      reader?.accessChanges.removeListener(check);
      content?.removeListener(check);
      active.dispose();
    }));
  }

  void _showAssignmentDetails(HomeAssignmentPreview item) {
    if (widget.cachedReader != null) return;
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

  Future<void> _hydratePromoMedia(HomePromoLoadResult promo) async {
    final mediaUser = _service.currentUserId;
    final generation = ++_promoMediaGeneration;
    if (promo.hidePromoStrip || promo.isDemoFallback || promo.cards.isEmpty) {
      if (!mounted ||
          generation != _promoMediaGeneration ||
          mediaUser != _service.currentUserId) return;
      setState(() {
        _promoImageBytes.clear();
        _promoIconBytes.clear();
        _promoImageStates.clear();
      });
      return;
    }

    // Mark image variants as loading until bytes arrive.
    final loadingStates = <String, ContentImageRenderState>{};
    for (final card in promo.cards) {
      final usesImage = contentCardVariantUsesImage(
        effectiveContentCardVariant(card.homePromo.cardVariant),
      );
      final identity = _promoIdentity(card);
      if (_promoAssetIdentities[card.id] != identity) {
        _promoImageBytes.remove(card.id);
        _promoIconBytes.remove(card.id);
      }
      _promoAssetIdentities[card.id] = identity;
      if (usesImage) {
        final cached = _promoImageBytes[card.id];
        loadingStates[card.id] = cached == null
            ? ContentImageRenderState.loading
            : ContentImageReady(cached);
      } else {
        loadingStates[card.id] = ContentImageRenderState.notApplicable;
      }
    }
    if (mounted && generation == _promoMediaGeneration) {
      setState(() => _promoImageStates
        ..clear()
        ..addAll(loadingStates));
    }
    _queuePromoImpressions();

    Future<void> hydrate(ManagedContentCard card) async {
      final version = '${card.id}|${card.schemaVersion}';
      final imageId = card.homePromo.imageAssetId?.trim();
      final iconId = card.homePromo.iconAssetId?.trim();
      final usesImage = contentCardVariantUsesImage(
        effectiveContentCardVariant(card.homePromo.cardVariant),
      );

      Future<void> image() async {
        if (imageId != null && imageId.isNotEmpty && usesImage) {
          Uint8List? bytes;
          try {
            bytes = await _contentMedia.fetchBytes(
              imageId,
              contentVersion: version,
            );
          } catch (_) {}
          if (!mounted ||
              generation != _promoMediaGeneration ||
              mediaUser != _service.currentUserId) return;
          setState(() {
            if (bytes != null && bytes.isNotEmpty) {
              _promoImageBytes[card.id] = bytes;
              _promoImageStates[card.id] = ContentImageReady(bytes);
            } else {
              _promoImageBytes.remove(card.id);
              _promoImageStates[card.id] = const ContentImageFailed();
            }
          });
          _queuePromoImpressions();
        } else if (usesImage) {
          if (!mounted ||
              generation != _promoMediaGeneration ||
              mediaUser != _service.currentUserId) return;
          setState(() {
            _promoImageBytes.remove(card.id);
            _promoImageStates[card.id] = ContentImageRenderState.missing;
          });
        }
      }

      Future<void> icon() async {
        if (iconId != null && iconId.isNotEmpty) {
          Uint8List? iconBytes;
          try {
            iconBytes = await _contentMedia.fetchBytes(
              iconId,
              contentVersion: '$version|icon',
            );
          } catch (_) {}
          if (!mounted ||
              generation != _promoMediaGeneration ||
              mediaUser != _service.currentUserId) return;
          if (iconBytes != null && iconBytes.isNotEmpty) {
            setState(() => _promoIconBytes[card.id] = iconBytes!);
          }
        } else {
          if (!mounted ||
              generation != _promoMediaGeneration ||
              mediaUser != _service.currentUserId) return;
          setState(() => _promoIconBytes.remove(card.id));
        }
      }

      await Future.wait([image(), icon()]);
    }

    for (var offset = 0; offset < promo.cards.length; offset += 2) {
      if (!mounted ||
          generation != _promoMediaGeneration ||
          mediaUser != _service.currentUserId) return;
      await Future.wait(promo.cards.skip(offset).take(2).map(hydrate));
    }
  }

  List<StudentHomePromoPlacement> _promoPlacements() {
    if (widget.homeContent?.isDenied('promo') == true) return const [];
    if (_promo.hidePromoStrip) return const [];
    if (_promo.isDemoFallback) {
      final demo = HomePromoPayload.demoStuckWithAssignment;
      return [
        StudentHomePromoPlacement(
          payload: demo,
          slot: 'after_assignments',
          showDemoBadge: true,
          onTap: () => _onHomePromoTap(payload: demo),
        ),
      ];
    }
    if (_promo.cards.isEmpty) return const [];
    return [
      for (final card in _promo.cards)
        if (_promoReady(card))
          StudentHomePromoPlacement(
            anchorKey: _promoKeys.putIfAbsent(card.id, GlobalKey.new),
            payload: card.homePromo,
            slot: card.homePromo.effectiveHomeSlot,
            showDemoBadge: card.showDemoBadge,
            onTap: widget.cachedReader != null ? null : _promoTapCallback(card),
            onDismiss: widget.cachedReader == null && card.homePromo.dismissible
                ? () => _onHomePromoDismiss(card)
                : null,
            imageBytes: _promoImageBytes[card.id],
            iconBytes: _promoIconBytes[card.id],
            imageState: _promoImageStates[card.id],
            imageLoading: _promoImageStates[card.id]?.isLoading == true,
          ),
    ];
  }

  void _maybeRecordPromoImpression(HomePromoLoadResult promo) {
    if (qaNoAutomaticWrites) return;
    if (widget.cachedReader != null) return;
    if (!mounted ||
        _data == null ||
        !(widget.activeListenable?.value ?? true) ||
        _loadUserId != _service.currentUserId ||
        ModalRoute.of(context)?.isCurrent == false ||
        promo.isDemoFallback ||
        promo.hidePromoStrip ||
        promo.loadError) {
      return;
    }
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
    for (final card in promo.cards) {
      if (!_promoReady(card)) continue;
      final box = _promoKeys[card.id]?.currentContext?.findRenderObject();
      if (box is! RenderBox ||
          !box.attached ||
          !box.hasSize ||
          !(box.localToGlobal(Offset.zero) & box.size).overlaps(bounds))
        continue;
      final id = card.id;
      if (!_recordedImpressionIds.add(id)) continue;
      unawaited(_promoService.recordEvent(id, 'impression'));
    }
  }

  void _queuePromoImpressions() {
    if (widget.cachedReader != null) return;
    if (!mounted || _impressionFramePending) return;
    _impressionFramePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _impressionFramePending = false;
      if (mounted && widget.cachedReader == null)
        _maybeRecordPromoImpression(_promo);
    });
  }

  bool _promoReady(ManagedContentCard card) =>
      !contentCardVariantUsesImage(
          effectiveContentCardVariant(card.homePromo.cardVariant)) ||
      (_promoAssetIdentities[card.id] == _promoIdentity(card) &&
          _promoImageStates[card.id] is ContentImageReady &&
          (_promoImageBytes[card.id]?.isNotEmpty ?? false));

  String _promoIdentity(ManagedContentCard card) =>
      '${card.schemaVersion}|${card.homePromo.imageAssetId}|${card.homePromo.iconAssetId}';

  VoidCallback? _promoTapCallback(ManagedContentCard card) {
    final payload = card.homePromo;
    final intent = ContentNavResolver.resolve(
      action: payload.action,
      ctaRoute: payload.ctaRoute,
      ctaUrl: payload.ctaUrl,
    );
    if (intent is ContentNavDisabled) return null;
    return () => _onHomePromoTap(card: card);
  }

  Future<void> _onHomePromoTap({
    ManagedContentCard? card,
    HomePromoPayload? payload,
  }) async {
    final modeRevision = _modeRevision;
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision;
    if (!stillOnline()) return;
    if (widget.cachedReader != null) return;
    final resolved = payload ?? card?.homePromo ?? _promo.payload;
    final managedId = card?.id;
    if (managedId != null && !_promo.isDemoFallback && !_promo.hidePromoStrip) {
      await _promoService.recordEvent(managedId, 'click');
    }

    final intent = ContentNavResolver.resolve(
      action: resolved.action,
      ctaRoute: resolved.ctaRoute,
      ctaUrl: resolved.ctaUrl,
    );
    if (intent is ContentNavNone || intent is ContentNavDisabled) {
      if (!stillOnline()) return;
      if (intent is ContentNavDisabled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Действие недоступно')),
        );
        return;
      }
      _showHelpDetails(resolved);
      return;
    }
    if (!stillOnline()) return;
    await const ContentNavExecutor().execute(
      context,
      intent,
      onUnavailableMessage: (message) {
        if (!stillOnline()) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
      onDisabled: () {
        if (!stillOnline()) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Действие недоступно')),
        );
      },
    );
  }

  Future<void> _onHomePromoDismiss(ManagedContentCard card) async {
    final modeRevision = _modeRevision;
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision;
    if (!stillOnline()) return;
    if (widget.cachedReader != null) return;
    if (_promo.isDemoFallback) {
      setState(() {
        _promo = const HomePromoLoadResult(intentionallyEmpty: true);
      });
      return;
    }
    try {
      await _promoService.dismiss(card.id);
      if (!stillOnline()) return;
      // Optimistic: remove only the dismissed card; empty must not resurrect demo.
      final remaining =
          _promo.cards.where((c) => c.id != card.id).toList(growable: false);
      setState(() {
        _promoImageBytes.remove(card.id);
        _promoIconBytes.remove(card.id);
        _promoImageStates.remove(card.id);
        _promo = remaining.isEmpty
            ? const HomePromoLoadResult(intentionallyEmpty: true)
            : HomePromoLoadResult(cards: remaining);
      });
      final refreshed = await _loadPromoSafe();
      if (!stillOnline()) return;
      setState(() => _promo = refreshed);
      unawaited(_hydratePromoMedia(refreshed));
    } catch (error) {
      if (!stillOnline()) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось скрыть карточку.')),
      );
    }
  }

  void _showHelpDetails(HomePromoPayload payload) {
    _showDetailsSheet(
      title: payload.title,
      icon: payload.iconData,
      accent: const Color(0xFF8A72D8),
      children: [
        Text(
          payload.subtitle,
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
