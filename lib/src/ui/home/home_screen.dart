import 'dart:async';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart'
    show kReleaseMode, listEquals, ValueListenable;
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
import 'package:student_platform/src/ui/home/home_frame_trace.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
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
  int _badgeRevision = 0;
  String? _badgeOwner;
  (String, String, String, int)? _badgeBinding;
  int _promoLoadGeneration = 0;
  int _modeRevision = 0;
  int _contentLayoutVisit = 0;
  final Set<String> _shownPromosThisVisit = {};
  final Set<String> _recordedImpressionIds = {};
  final Map<String, GlobalKey> _promoKeys = {};
  bool _impressionFramePending = false;
  final Map<String, String> _promoAssetIdentities = {};
  final Map<String, Uint8List> _promoImageBytes = {};
  final Map<String, Uint8List> _promoIconBytes = {};
  final Map<String, ContentImageRenderState> _promoImageStates = {};
  final _newsCoverProviders = <Uint8List, ImageProvider>{};
  final Map<String, HomeContentSnapshot> _lateOptionalContent = {};
  int _contentRevision = 0;
  SessionCapabilities? _observedContentCaps;
  CapabilityPermit? _contentPermit;
  bool _contentRebuildScheduled = false;
  CachedHomeScheduleReader? _queuedCachedReload;
  bool _cachedRefreshScheduled = false;
  final Set<String> _hiddenDoneAssignmentIds = {};
  final Set<String> _markingDoneAssignmentIds = {};
  StreamSubscription<InAppNotificationEvent>? _inAppSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.activeListenable?.addListener(_onHomeActiveChanged);
    PublicNewsImageCache.shared.invalidations.addListener(_clearDisplayedNewsCovers);
    widget.homeContent?.addListener(_onContentAccessChanged);
    _bindContentCapabilities();
    CachedHomeScheduleReader.homeRefreshFor(widget.cachedReader)?.addListener(_onCachedReadReady);
    if (widget.cachedReader == null) {
      _inAppSub = InAppNotificationBus.instance.stream.listen(_onInAppEvent);
    }
  }

  void _onHomeActiveChanged() {
    if (widget.activeListenable?.value == true && mounted) {
      setState(_beginContentLayoutVisit);
      if (_data != null && HomeFrameTrace.enabled) {
        final trace = HomeFrameTrace();
        trace.mark('home_tab_return', counts: _readyCounts(_data!));
        trace.markNextRaster('home_tab_first',
            current: () => mounted && widget.activeListenable?.value == true);
      }
    }
    _queuePromoImpressions();
  }

  Future<void> _refreshFromGesture() {
    setState(_beginContentLayoutVisit);
    return _load();
  }

  void _beginContentLayoutVisit() {
    _contentLayoutVisit++;
    _shownPromosThisVisit.clear();
  }

  void _clearDisplayedNewsCovers() {
    _newsCoverProviders.clear();
    final data = _data;
    if (mounted && data != null) {
      setState(() => _data = _withoutNewsCovers(data));
    }
  }

  HomeDashboardData _withoutNewsCovers(HomeDashboardData data) =>
      data.withNews(_clearNewsBytes(data.news));

  ImageProvider _newsCoverProvider(Uint8List bytes) =>
      _newsCoverProviders.putIfAbsent(bytes, () {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final targetWidth = (288 * ratio).round().clamp(288, 1440).toInt();
        return ResizeImage.resizeIfNeeded(targetWidth, null, MemoryImage(bytes));
      });

  Future<void> _prepareFirstNewsCovers(List<Uint8List?> covers,
      bool Function() current, Duration remaining) async {
    if (!current()) return;
    await Future.wait([
      for (final bytes in covers)
        if (bytes != null)
          precacheImage(_newsCoverProvider(bytes), context, onError: (_, __) {}),
    ]).timeout(remaining, onTimeout: () => []);
  }

  List<Uint8List?> _firstCoverBytes(HomeDashboardData data) => [
        for (final item in data.news.take(4))
          item.usesImage ? item.imageBytes : null,
      ];

  List<HomeNewsItem> _clearNewsBytes(List<HomeNewsItem> items) => [
        for (final item in items) item.copyWith(clearImageBytes: true),
      ];

  void _presentDashboard(HomeDashboardData next,
      {PreparedHomePromos? promos}) {
    final used = next.news.map((item) => item.imageBytes).toSet();
    _newsCoverProviders.removeWhere((bytes, _) => !used.contains(bytes));
    setState(() {
      _data = next;
      _error = null;
      if (promos != null) _applyPromos(promos);
    });
  }

  void _onContentAccessChanged() {
    _contentRevision++;
    _lateOptionalContent.clear();
    if (widget.cachedReader != null) _onCachedReadReady();
    if (mounted) setState(() {});
  }

  void _bindContentCapabilities() {
    final next = widget.homeContentCapabilities;
    if (!identical(next, _observedContentCaps)) {
      _observedContentCaps?.removeListener(_onContentCapabilityChanged);
      _observedContentCaps = next;
      next?.addListener(_onContentCapabilityChanged);
    }
    _contentPermit = next?.capture(SessionCapability.cachedRead);
  }

  bool get _cachedContentAllowed {
    final reader = widget.cachedReader;
    if (reader == null) return true;
    final caps = _observedContentCaps, permit = _contentPermit;
    return caps != null && permit != null && reader.permitsContent(caps, permit);
  }

  void _onContentCapabilityChanged() {
    if (widget.cachedReader == null) {
      _contentPermit = _observedContentCaps?.capture(SessionCapability.cachedRead);
      return;
    }
    _contentRevision++;
    _lateOptionalContent.clear();
    _contentPermit = _observedContentCaps?.capture(SessionCapability.cachedRead);
    final data = _data;
    if (data != null) {
      _data = data.withNews(const [], loading: false);
      _newsCoverProviders.clear();
    }
    _promo = const HomePromoLoadResult(intentionallyEmpty: true);
    _promoImageBytes.clear(); _promoIconBytes.clear(); _promoImageStates.clear();
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle || phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
    } else if (!_contentRebuildScheduled) {
      _contentRebuildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _contentRebuildScheduled = false;
        if (mounted) setState(() {});
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
    _onCachedReadReady();
  }

  void _onCachedReadReady() {
    if (_cachedRefreshScheduled) return;
    _cachedRefreshScheduled = true;
    final reader = widget.cachedReader;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _cachedRefreshScheduled = false;
      if (mounted && reader != null && identical(widget.cachedReader, reader) && reader.canRead) {
        if (_loadInFlight != null) {
          _queuedCachedReload = reader;
        } else {
          unawaited(_load());
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = AuthSessionScopeHost.maybeOf(context);
    if (_serviceInitialized && identical(source, _authScope)) return;
    if (_serviceInitialized) {
      _authScope?.removeListener(_onAuthScopeChanged);
      if (_ownsService) _service.dispose();
      _resetVisibleSnapshot();
      _loadInFlight = null;
      _loadUserId = null;
      _loadSessionId = null;
      _loadAuthScope = null;
      _promoLoadGeneration++;
    }
    _authScope = source;
    _authScope?.addListener(_onAuthScopeChanged);
    _ownsService = widget.dashboardService == null;
    _service = widget.dashboardService ?? _createDashboardService(source);
    _serviceInitialized = true;
    unawaited(_load());
    if (source != null && source.capture() == null) {
      unawaited(source.ready.then((_) {
        if (mounted && identical(_authScope, source) && source.capture() != null) {
          return _refreshUnreadBadge();
        }
      }));
    }
  }

  HomeDashboardService _createDashboardService(AuthSessionScope? scope) =>
      HomeDashboardService(
          sessionScope: scope, readVerifiedNews: _readVerifiedOnlineNews);

  Future<HomeContentSnapshot?> _readVerifiedOnlineNews() async {
    if (!mounted || widget.cachedReader != null) return null;
    final content = widget.homeContent;
    final barrier = widget.onlineBarrier;
    if (content == null || barrier == null || !barrier.isOpen) return null;
    final saved = await content.readOnline('news', barrier);
    return mounted && widget.cachedReader == null &&
            identical(content, widget.homeContent) &&
            identical(barrier, widget.onlineBarrier) && barrier.isOpen &&
            !content.isDenied('news')
        ? saved
        : null;
  }

  void _onAuthScopeChanged() {
    if (!mounted) return;
    _contentRevision++;
    _queuedCachedReload = null;
    _lateOptionalContent.clear();
    _bindContentCapabilities();
    _badgeRevision++;
    final scope = _authScope;
    final owner = scope?.capture();
    final binding = owner == null ? null : scope?.bindingFor(owner, '${SupabaseConfig.url}/auth/v1');
    final nextBinding = binding == null || scope == null ? null :
        (binding.issuer, binding.userId, binding.sessionId, scope.generation);
    if ((nextBinding == null || nextBinding != _badgeBinding) && _unreadNotificationCount != 0) {
      setState(() => _unreadNotificationCount = 0);
    }
    if (_authScope != null && owner == null) {
      setState(() {
        _resetVisibleSnapshot();
        _loadUserId = null;
        _loadSessionId = null;
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
    if (!identical(oldWidget.activeListenable, widget.activeListenable)) {
      oldWidget.activeListenable?.removeListener(_onHomeActiveChanged);
      widget.activeListenable?.addListener(_onHomeActiveChanged);
      _beginContentLayoutVisit();
    }
    final contentChanged = !identical(oldWidget.homeContent, widget.homeContent) ||
        !identical(oldWidget.homeContentCapabilities, widget.homeContentCapabilities);
    if (contentChanged) {
      _contentRevision++;
      _lateOptionalContent.clear();
      _bindContentCapabilities();
      if (widget.cachedReader != null) _onCachedReadReady();
    }
    if (!identical(oldWidget.homeContent, widget.homeContent)) {
      oldWidget.homeContent?.removeListener(_onContentAccessChanged);
      widget.homeContent?.addListener(_onContentAccessChanged);
    }
    final modeChanged = !identical(oldWidget.cachedReader, widget.cachedReader);
    if (modeChanged) {
      _contentRevision++;
      _bindContentCapabilities();
      _queuedCachedReload = null;
      _lateOptionalContent.clear();
      CachedHomeScheduleReader.homeRefreshFor(oldWidget.cachedReader)?.removeListener(_onCachedReadReady);
      CachedHomeScheduleReader.homeRefreshFor(widget.cachedReader)?.addListener(_onCachedReadReady);
    }
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
      _inAppSub?.cancel();
      _inAppSub = widget.cachedReader == null
          ? InAppNotificationBus.instance.stream.listen(_onInAppEvent)
          : null;
      _unreadNotificationCount = 0;
    }
    if (serviceChanged) {
      if (_ownsService) _service.dispose();
      _ownsService = widget.dashboardService == null;
      _service = widget.dashboardService ?? _createDashboardService(_authScope);
    }
    _resetVisibleSnapshot();
    _loadInFlight = null;
    _loadUserId = null;
    _loadSessionId = null;
    _loadAuthScope = null;
    _promoLoadGeneration++;
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.activeListenable?.removeListener(_onHomeActiveChanged);
    PublicNewsImageCache.shared.invalidations.removeListener(_clearDisplayedNewsCovers);
    widget.homeContent?.removeListener(_onContentAccessChanged);
    _observedContentCaps?.removeListener(_onContentCapabilityChanged);
    CachedHomeScheduleReader.homeRefreshFor(widget.cachedReader)?.removeListener(_onCachedReadReady);
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
    final revision = ++_badgeRevision;
    final scope = _authScope;
    final owner = scope?.capture();
    final userId = _service.currentUserId;
    if (_badgeOwner != userId) {
      _badgeOwner = userId;
      if (_unreadNotificationCount != 0) {
        setState(() => _unreadNotificationCount = 0);
      }
    }
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision &&
        revision == _badgeRevision && userId == _service.currentUserId &&
        (scope == null || (identical(scope, _authScope) && owner != null && scope.isCurrent(owner)));
    if (!stillOnline()) return;
    if (widget.cachedReader != null) return;
    try {
      final count = await _notificationsApi.unreadCount();
      if (!stillOnline()) return;
      final binding = owner == null ? null : scope?.bindingFor(owner, '${SupabaseConfig.url}/auth/v1');
      _badgeBinding = binding == null || scope == null ? null :
          (binding.issuer, binding.userId, binding.sessionId, scope.generation);
      setState(() => _unreadNotificationCount = count);
    } catch (_) {}
  }

  Future<void>? _loadInFlight;
  String? _loadUserId;
  String? _loadSessionId;
  AuthOperationScope? _loadAuthScope;
  void _resetVisibleSnapshot() {
    _data = null;
    _newsCoverProviders.clear();
    _error = null;
    _loading = true;
    _beginContentLayoutVisit();
    _avatarPrecacheKey = null;
    _applyPromos(const PreparedHomePromos(
        promo: HomePromoLoadResult(intentionallyEmpty: true)));
    _recordedImpressionIds.clear();
    _promoKeys.clear();
    _hiddenDoneAssignmentIds.clear();
    _markingDoneAssignmentIds.clear();
  }

  Future<void> _load() {
    final userId = _service.currentUserId;
    final scope = _authScope;
    final operationScope = scope?.capture();
    final sessionId = operationScope == null
        ? null
        : scope?.bindingFor(operationScope, '${SupabaseConfig.url}/auth/v1')?.sessionId;
    if (_loadInFlight != null &&
        _loadUserId == userId &&
        _loadAuthScope == operationScope) return _loadInFlight!;
    if (_loadUserId != userId || _loadSessionId != sessionId) {
      _resetVisibleSnapshot();
    }
    _loadUserId = userId;
    _loadSessionId = sessionId;
    _loadAuthScope = operationScope;
    final work = _loadDashboard();
    _loadInFlight = work;
    void release() {
      if (!identical(_loadInFlight, work)) return;
      _loadInFlight = null;
      final queued = _queuedCachedReload;
      _queuedCachedReload = null;
      if (queued != null) scheduleMicrotask(() {
        if (mounted && identical(widget.cachedReader, queued) && queued.canRead) unawaited(_load());
      });
    }

    unawaited(work.then<void>((_) => release(),
        onError: (Object _, StackTrace __) => release()));
    return work;
  }

  Future<void> _loadDashboard() async {
    final trace = HomeFrameTrace();
    final reader = widget.cachedReader;
    if (reader != null) {
      final firstCoreFrame = _data == null;
      try {
        final content = widget.homeContent;
        final caps = widget.homeContentCapabilities;
        final permit = _contentPermit;
        final contentRevision = _contentRevision;
        bool currentContext() => mounted && identical(widget.cachedReader, reader) &&
            identical(widget.homeContent, content) && identical(widget.homeContentCapabilities, caps) &&
            contentRevision == _contentRevision && reader.canRead;
        bool currentContent() => currentContext() && content != null && caps != null && permit != null &&
            identical(permit, _contentPermit) && reader.permitsContent(caps, permit);
        final coverRevision = PublicNewsImageCache.shared.invalidations.value;
        bool currentNews() => currentContent() && content?.isDenied('news') != true;
        bool currentCovers() => currentNews() &&
            PublicNewsImageCache.shared.invalidations.value == coverRevision;
        List<HomeNewsItem> permittedNews(List<HomeNewsItem> items) =>
            !currentNews() ? const [] : currentCovers() ? items : _clearNewsBytes(items);
        Future<HomeContentSnapshot?> readOptional(String section) async {
          if (content == null || caps == null || !currentContent()) return null;
          try {
            if (content.isDenied(section)) return null;
            final late = _lateOptionalContent[section];
            if (late != null) return late;
            var timedOut = false;
            final pending = content.read(section, caps);
            pending.then((value) {
              if (timedOut && value != null && currentContent()) {
                if (content.isDenied(section)) return;
                _lateOptionalContent[section] = value;
                _onCachedReadReady();
              }
            }, onError: (Object _, StackTrace __) {});
            return await pending.timeout(const Duration(seconds: 1), onTimeout: () {
              timedOut = true;
              return null;
            });
          } catch (error) {
            debugPrint(
                '[home-cache] $section unavailable: ${error.runtimeType}');
            return null;
          }
        }

        Future<List<HomeNewsItem>> readNewsForDisplay() async {
          final saved = await readOptional('news');
          if (!currentNews()) return const [];
          if (saved == null) return permittedNews(_data?.news ?? const []);
          final news = <HomeNewsItem>[];
          for (final row in saved.rows) {
            try {
              final item = mapPublishedNews(row);
              final key = row['_offline_image'];
              news.add(item.copyWith(
                  imageBytes: key is String ? saved.images[key] : null));
            } catch (_) {
              // A malformed optional card cannot hide the dashboard.
            }
          }
          if (news.isEmpty) return news;
          if (!currentCovers()) return permittedNews(news);
          List<HomeNewsItem> verified;
          try {
            verified = await _service.validateNewsImages(news)
                .timeout(const Duration(seconds: 1));
          } catch (_) {
            verified = _clearNewsBytes(news);
          }
          if (!currentCovers()) return permittedNews(news);
          final prior = {
            for (final item in _data?.news ?? const <HomeNewsItem>[])
              item.id: item
          };
          verified = [
            for (final item in verified)
              if (prior[item.id] case final old?
                  when old.imageCacheKey?.id == item.imageCacheKey?.id &&
                      item.imageBytes != null && listEquals(old.imageBytes, item.imageBytes))
                item.copyWith(imageBytes: old.imageBytes)
              else
                item,
          ];
          if (firstCoreFrame) {
            await _prepareFirstNewsCovers([
              for (final item in verified.take(4))
                item.usesImage ? item.imageBytes : null,
            ], currentCovers, const Duration(milliseconds: 600));
          }
          return permittedNews(verified);
        }

        if (!currentContext()) return;
        final dashboardWork = reader.readDashboard();
        final newsWork = readNewsForDisplay();
        final promoWork = readOptional('promo').then((saved) async {
          trace.mark('offline_promo_read', counts: {
            'savedFiles': saved?.images.length ?? 0,
          });
          if (saved == null || !currentContent()) return null;
          final candidate = PreparedHomePromos.fromSnapshot(saved);
          if (candidate == null) return null;
          final prepared = await _preparePromos(candidate);
          trace.mark('offline_promo_decoded', counts: {
            'covers': prepared.images.length, 'icons': prepared.icons.length,
          });
          return prepared;
        });
        final snapshot = await dashboardWork;
        trace.mark('offline_core_read');
        final verifiedNews = await newsWork;
        final promos = await promoWork;
        if (!currentContext()) return;
        _presentDashboard(
            snapshot.withNews(permittedNews(verifiedNews), loading: false),
            promos: currentContent() ? promos : null);
        _loading = false;
        if (firstCoreFrame) {
          trace.mark('offline_home_ready', counts: _readyCounts(_data!));
          trace.markNextRaster('offline_home_first', current: () =>
              currentContext() && widget.activeListenable?.value != false);
        }
      } catch (error) {
        if (!mounted || widget.cachedReader != reader) return;
        setState(() {
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
    final owner = _loadAuthScope;
    final scope = _authScope;
    final coverRevision = PublicNewsImageCache.shared.invalidations.value;
    bool current() => mounted &&
        promoGeneration == _promoLoadGeneration &&
        _service.currentUserId == userId &&
        identical(scope, _authScope) &&
        (scope == null || (owner != null && scope.isCurrent(owner))) &&
        (onlineBarrier == null || onlineBarrier.isOpen);
    final cachedPromos = hadData
        ? Future<PreparedHomePromos?>.value(null)
        : _restorePromos(current, trace);
    HomeDashboardData currentCovers(HomeDashboardData data) =>
        PublicNewsImageCache.shared.invalidations.value == coverRevision
            ? data
            : _withoutNewsCovers(data);
    HomeDashboardData? pending;
    Future<void>? firstPaint;
    var firstFramePending = false;
    void commit(HomeDashboardData data, {PreparedHomePromos? promos}) {
      if (!current()) return;
      if (!reportedFirstContent &&
          (!kReleaseMode || const bool.fromEnvironment('STARTUP_TRACE'))) {
        reportedFirstContent = true;
        debugPrint(
            '[home-perf] first partial data ${firstContentClock.elapsedMilliseconds}ms');
      }
      _presentDashboard(currentCovers(data), promos: promos);
      _warmProfileAvatar(data.profile);
    }

    void refreshOptionalContent() {
      if (!current()) return;
      final content = widget.homeContent;
      if (content != null && onlineBarrier != null) {
        unawaited(content.warm(HomeContentSection.news, onlineBarrier)
            .catchError((Object _) {}));
      }
      unawaited(_refreshPromo(current));
    }

    void offer(HomeDashboardData data) {
      if (!current()) return;
      pending = data;
      if (_data != null) {
        if (!firstFramePending) commit(data);
        return;
      }
      firstPaint ??= () async {
        trace.mark('home_core_ready');
        const budget = Duration(milliseconds: 600);
        final initialCovers = _firstCoverBytes(currentCovers(data));
        final preparedNews = _prepareFirstNewsCovers(initialCovers, current, budget);
        final promos = await cachedPromos;
        await preparedNews;
        if (!current()) return;
        final candidate = pending!;
        final covers = _firstCoverBytes(currentCovers(candidate));
        if (!listEquals(initialCovers, covers)) {
          await _prepareFirstNewsCovers(covers, current, budget);
        }
        trace.mark('home_cover_decode_complete');
        if (!current()) return;
        final latest = pending!;
        final sameCovers = listEquals(covers, _firstCoverBytes(currentCovers(latest)));
        final first = sameCovers ? latest : candidate;
        firstFramePending = true;
        commit(first, promos: promos);
        trace.mark('home_ready', counts: _readyCounts(_data!));
        trace.markNextRaster('home_first', current: () =>
            current() && widget.activeListenable?.value != false);
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          firstFramePending = false;
          if (!current() || identical(pending, first)) return;
          final update = pending!;
          final updateCovers = _firstCoverBytes(currentCovers(update));
          if (!listEquals(covers, updateCovers)) {
            await _prepareFirstNewsCovers(updateCovers, current, budget);
          }
          if (current() && identical(pending, update)) commit(update);
        });
        refreshOptionalContent();
      }();
    }

    if (hadData) refreshOptionalContent();
    unawaited(_refreshUnreadBadge());
    try {
      final next = await _service
          .load(previous: _data, onUpdate: offer)
          .timeout(const Duration(seconds: 18));
      offer(next);
      await firstPaint;
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

  Future<PreparedHomePromos?> _restorePromos(
      bool Function() current, HomeFrameTrace trace) async {
    Future<PreparedHomePromos> decode(PreparedHomePromos promo) async {
      trace.mark('promo_disk_read', counts: {
        'covers': promo.images.length, 'icons': promo.icons.length,
      });
      final prepared = await _preparePromos(promo);
      trace.mark('promo_decoded', counts: {
        'covers': prepared.images.length, 'icons': prepared.icons.length,
      });
      return prepared;
    }
    try {
      return await (() async {
        final content = widget.homeContent;
        final barrier = widget.onlineBarrier;
        if (content != null && barrier != null) {
          final saved = await content.readOnline('promo', barrier);
          if (!current() || content.isDenied('promo') || saved == null) return null;
          final candidate = PreparedHomePromos.fromSnapshot(saved);
          return candidate == null ? null : decode(candidate);
        }
        final cached = await _promoService.loadCached();
        if (!current() || cached.isDemoFallback) return null;
        final stored = await _collectPromoMedia(cached, current, local: true);
        return current() ? decode(stored) : null;
      })().timeout(const Duration(seconds: 2), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshPromo(bool Function() current) async {
    Future<PreparedHomePromos?> prepare(PreparedHomePromos candidate) async {
      if (!current()) return null;
      final ready = await _preparePromos(candidate);
      final complete = ready.promo.cards.every((card) {
        final payload = card.homePromo;
        final needsImage = contentCardVariantUsesImage(
            effectiveContentCardVariant(payload.cardVariant));
        return (!needsImage || ready.images.containsKey(card.id)) &&
            ((payload.iconAssetId?.trim().isEmpty ?? true) ||
                ready.icons.containsKey(card.id));
      });
      return current() && complete ? ready : null;
    }

    try {
      final content = widget.homeContent;
      final barrier = widget.onlineBarrier;
      PreparedHomePromos? next;
      if (content != null && barrier != null) {
        next = await content.refreshPromo(barrier, prepare: prepare,
            onVisibleIds: (ids) {
          if (!current() || _promo.cards.every((card) => ids.contains(card.id))) {
            return;
          }
          final cards = _promo.cards.where((card) => ids.contains(card.id)).toList();
          setState(() => _applyPromos(PreparedHomePromos(
                promo: HomePromoLoadResult(cards: cards, intentionallyEmpty: cards.isEmpty),
                images: Map.of(_promoImageBytes)..removeWhere((id, _) => !ids.contains(id)),
                icons: Map.of(_promoIconBytes)..removeWhere((id, _) => !ids.contains(id)),
              )));
        });
      } else {
        final promo = await _promoService.load().timeout(const Duration(seconds: 12));
        if (!current() || promo.loadError) return;
        next = await prepare(await _collectPromoMedia(promo, current));
      }
      final ready = next;
      if (!current() || ready == null) return;
      setState(() => _applyPromos(ready));
      _queuePromoImpressions();
    } catch (_) {
      // Keep the rendered snapshot through temporary transport failures.
    }
  }

  Future<PreparedHomePromos> _preparePromos(PreparedHomePromos promos) =>
      promos.prepareImages(context).timeout(const Duration(milliseconds: 800),
          onTimeout: () => PreparedHomePromos(promo: promos.promo));

  Future<PreparedHomePromos> _collectPromoMedia(
      HomePromoLoadResult promo, bool Function() current, {bool local = false}) async {
    final images = <String, Uint8List>{};
    final icons = <String, Uint8List>{};
    Future<void> fetch(String? id, String version, String cardId,
        Map<String, Uint8List> target) async {
      if (id == null || id.trim().isEmpty || !current()) return;
      try {
        final bytes = local
            ? await _contentMedia.readCachedBytes(id, contentVersion: version)
            : await _contentMedia.fetchBytes(id, contentVersion: version);
        if (current() && bytes != null && bytes.isNotEmpty) target[cardId] = bytes;
      } catch (_) {}
    }

    for (var offset = 0; current() && offset < promo.cards.length; offset += 2) {
      await Future.wait([
        for (final card in promo.cards.skip(offset).take(2)) ...[
          if (contentCardVariantUsesImage(
              effectiveContentCardVariant(card.homePromo.cardVariant)))
            fetch(card.homePromo.imageAssetId, '${card.id}|${card.schemaVersion}',
                card.id, images),
          fetch(card.homePromo.iconAssetId, '${card.id}|${card.schemaVersion}|icon',
              card.id, icons),
        ],
      ]);
    }
    return PreparedHomePromos(promo: promo, images: images, icons: icons);
  }

  void _applyPromos(PreparedHomePromos prepared) {
    _promo = prepared.promo;
    _promoAssetIdentities
      ..clear()
      ..addEntries(_promo.cards.map((card) => MapEntry(card.id, _promoIdentity(card))));
    _promoImageBytes
      ..clear()
      ..addAll(prepared.images);
    _promoIconBytes
      ..clear()
      ..addAll(prepared.icons);
    _promoImageStates
      ..clear()
      ..addEntries(prepared.images.entries
          .map((image) => MapEntry(image.key, ContentImageReady(image.value))));
  }

  Map<String, int> _readyCounts(HomeDashboardData data) => {
        'profile': data.profile.id.isEmpty ? 0 : 1,
        'schedule': data.todayLessons.length,
        'assignments': data.assignments.length,
        'newsCovers': _firstCoverBytes(data).whereType<Uint8List>().length,
        'promoCovers': _promoImageBytes.length,
        'promoIcons': _promoIconBytes.length,
      };

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
    final newsUser = _loadUserId;
    final newsOwner = _loadAuthScope;
    final promoPlacements = _promoPlacements();
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
          child: MediaQuery.removePadding(
            context: context,
            removeTop: widget.cachedReader != null,
            child: NotificationListener<ScrollNotification>(
            onNotification: (_) {
              _queuePromoImpressions();
              return false;
            },
            child: StudentHomeView(
              data: _toPresentationData(data),
              newsLoading: _cachedContentAllowed &&
                  widget.homeContent?.isDenied('news') != true && data.newsLoading,
              decodedCoverNewsIds: {
                for (final item in data.news)
                  if (_requiresDecodedNewsCover(item)) item.id,
              },
              contentLayoutVisit: _contentLayoutVisit,
              notificationCount: _unreadNotificationCount,
              onRefresh: _refreshFromGesture,
              onNotificationsTap:
                  widget.cachedReader == null ? _openNotifications : null,
              onNewsTap: (index) => _showNewsFeed(data.news, index,
                  userId: newsUser, owner: newsOwner),
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
              homePromo: !_cachedContentAllowed || _promo.hidePromoStrip || _promo.cards.length != 1
                  ? null
                  : (_promo.isDemoFallback ? null : _promo.payload),
              homePromoIsDemo: _promo.showDemoBadge && _promo.cards.length <= 1,
              hideHomePromo: promoPlacements.isEmpty,
              homePromoPlacements: promoPlacements,
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
          !_cachedContentAllowed || widget.homeContent?.isDenied('news') == true ? const [] : data.news),
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

  bool _requiresDecodedNewsCover(HomeNewsItem item) =>
      item.id == '9658bbcf-7fc8-48cc-ae1f-21b1a0ad1523' && item.usesImage;

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
          imageProvider: item.imageBytes == null ? null : _newsCoverProvider(item.imageBytes!),
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
    await _refreshUnreadBadge();
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

  bool _openingNewsStory = false;

  Future<void> _showNewsFeed(List<HomeNewsItem> news, int initialIndex,
      {required String? userId, required AuthOperationScope? owner}) async {
    if (_openingNewsStory || !_cachedContentAllowed || news.isEmpty) return;
    final service = _service;
    final scope = _authScope;
    if (service.currentUserId != userId ||
        (scope != null && (owner == null || !scope.isCurrent(owner)))) return;
    final reader = widget.cachedReader;
    final barrier = widget.onlineBarrier;
    final content = widget.homeContent;
    final contentCaps = widget.homeContentCapabilities;
    final contentPermit = _contentPermit;
    final initial = news[initialIndex.clamp(0, news.length - 1)];
    final welcome = news.where(_requiresDecodedNewsCover).firstOrNull;
    final navigator = Navigator.of(context);
    final coverChanges = PublicNewsImageCache.shared.invalidations;
    final coverRevision = coverChanges.value;
    bool articleCurrent(HomeNewsItem article) => _data?.news.any((item) =>
        item.id == article.id &&
        item.imageCacheKey?.path == article.imageCacheKey?.path) == true;
    bool current() =>
        mounted &&
        navigator.mounted &&
        articleCurrent(initial) &&
        identical(_service, service) &&
        service.currentUserId == userId &&
        identical(widget.cachedReader, reader) &&
        identical(widget.onlineBarrier, barrier) &&
        identical(widget.homeContent, content) &&
        identical(widget.homeContentCapabilities, contentCaps) &&
        (reader == null || (identical(_contentPermit, contentPermit) && _cachedContentAllowed)) &&
        (reader == null || reader.canRead) &&
        (barrier == null || barrier.isOpen) &&
        (scope == null || (owner != null && scope.isCurrent(owner))) &&
        content?.isDenied('news') != true;
    bool coverCurrent() => current() && coverChanges.value == coverRevision;
    Future<Uint8List?> localCover(HomeNewsItem source) async {
      if (!source.usesImage || !coverCurrent()) return null;
      try {
        final validated = await service
            .validateNewsImages([source])
            .timeout(const Duration(seconds: 1), onTimeout: () => []);
        return coverCurrent() ? validated.firstOrNull?.imageBytes : null;
      } catch (_) {
        return null;
      }
    }

    final trace = HomeFrameTrace();
    Future<StudentHomeNews?> prepareCover(
        HomeNewsItem item, Future<Uint8List?> local) async {
      final verified = await local;
      if (!coverCurrent() || !articleCurrent(item)) return null;
      final selected = identical(item, initial);
      if (selected) {
        trace.mark('story_cover_read',
            counts: {'files': verified?.isNotEmpty == true ? 1 : 0});
      }
      if (verified == null || verified.isEmpty) return null;
      final bytes = listEquals(item.imageBytes, verified)
          ? item.imageBytes!
          : verified;
      final viewport = MediaQuery.of(context);
      final width = (viewport.size.width * viewport.devicePixelRatio)
          .ceil().clamp(288, 1440).toInt();
      final provider = ResizeImage.resizeIfNeeded(width, null, MemoryImage(bytes));
      var decoded = true;
      await precacheImage(provider, context, onError: (_, __) => decoded = false)
          .timeout(const Duration(milliseconds: 600), onTimeout: () {
        decoded = false;
      });
      final ready = decoded && coverCurrent() && articleCurrent(item);
      if (selected) trace.mark('story_cover_decoded', counts: {'covers': ready ? 1 : 0});
      return ready ? _presentationNews([item.copyWith(clearImageBytes: true)])
          .single.copyWith(imageBytes: bytes, imageProvider: provider) : null;
    }

    // Only consult local media before opening. Include the welcome page in
    // the swipe sequence only when its authorized cover is already decoded.
    _openingNewsStory = true;
    late final Future<Uint8List?> initialLocal;
    StudentHomeNews? readyInitial;
    StudentHomeNews? readyWelcome;
    try {
      initialLocal = localCover(initial);
      final opening = prepareCover(initial, initialLocal);
      final extraWelcome = welcome != null && !identical(welcome, initial) &&
              welcome.imageBytes != null
          ? prepareCover(welcome, localCover(welcome))
          : null;
      readyInitial = await opening;
      readyWelcome = identical(welcome, initial) ? readyInitial : await extraWelcome;
    } finally {
      _openingNewsStory = false;
    }
    if (!current() || widget.activeListenable?.value == false) return;
    final includedWelcome = welcome != null && readyWelcome != null &&
        coverCurrent() && articleCurrent(welcome) ? welcome : null;
    if (_requiresDecodedNewsCover(initial) && includedWelcome == null) return;
    bool routeCurrent() => current() && (includedWelcome == null ||
        (coverCurrent() && articleCurrent(includedWelcome)));
    final shown = [
      for (final item in news)
        if (!_requiresDecodedNewsCover(item) || identical(item, includedWelcome)) item,
    ];
    final byId = {for (final item in shown) item.id: item};
    final presentation = _presentationNews(
        shown.map((item) => item.copyWith(clearImageBytes: true)).toList());
    final initialPresentation = [
      for (final item in presentation)
        if (item.id == readyInitial?.id) readyInitial!
        else if (item.id == readyWelcome?.id) readyWelcome!
        else item,
    ];
    final safeIndex = shown.indexWhere((item) => item.id == initial.id);

    final active = ValueNotifier<bool>(true);
    ModalBottomSheetRoute<void>? sheetRoute;
    var tracedFirstVisible = false;
    void check() {
      if (routeCurrent()) return;
      void close() {
        final target = sheetRoute;
        if (target == null || !target.isActive) return;
        active.value = false;
        if (navigator.mounted) {
          navigator.removeRoute(target);
        }
      }
      if (SchedulerBinding.instance.schedulerPhase ==
          SchedulerPhase.persistentCallbacks) {
        WidgetsBinding.instance.addPostFrameCallback((_) => close());
      } else {
        close();
      }
    }

    void mark(String id, {bool closed = false}) {
      if (!routeCurrent()) return;
      if (barrier == null) {
        unawaited(service.markNewsSeen(id, closed: closed));
      } else {
        unawaited(barrier.run(() => service.markNewsSeen(id, closed: closed)));
      }
    }

    final removeClose = barrier?.onClose(check);
    coverChanges.addListener(check);
    scope?.addListener(check);
    reader?.accessChanges.addListener(check);
    content?.addListener(check);
    contentCaps?.addListener(check);
    if (reader == null) mark(presentation[safeIndex].id);
    sheetRoute = ModalBottomSheetRoute<void>(
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (_) {
        Widget sheet() => StudentNewsStorySheet(
              news: coverCurrent() ? initialPresentation : presentation,
              initialIndex: safeIndex,
              onPageChanged: reader == null ? (id) => mark(id) : null,
              onClosed: reader == null ? (id) => mark(id, closed: true) : null,
              resolveImage: (item) async {
                if (!routeCurrent() || !coverCurrent()) return null;
                final source = byId[item.id];
                if (source == null) return null;
                final bytes = await (source == initial ? initialLocal : localCover(source));
                if (!routeCurrent() || !coverCurrent()) return null;
                if (bytes != null || reader != null) return bytes;
                final downloaded = barrier == null
                    ? await service.resolveNewsImageBytes(source)
                    : await service.resolveGuardedStoryImage(source, barrier,
                        current: () => routeCurrent() && coverCurrent());
                return routeCurrent() && coverCurrent() ? downloaded : null;
              },
            );
        final changes = <Listenable>[
          active,
          coverChanges,
          if (reader != null) reader.accessChanges,
          if (widget.homeContent != null) widget.homeContent!,
          if (contentCaps != null) contentCaps,
        ];
        final readerView = ListenableBuilder(
            listenable: Listenable.merge(changes),
            builder: (_, __) => active.value &&
                    routeCurrent() &&
                    (reader == null || reader.canRead) &&
                    widget.homeContent?.isDenied('news') != true
                ? sheet()
                : const SizedBox.shrink());
        final animation = sheetRoute?.animation;
        if (!HomeFrameTrace.enabled || animation == null) return readerView;
        return AnimatedBuilder(
          animation: animation,
          child: readerView,
          builder: (_, child) {
            if (!tracedFirstVisible && animation.value > 0 && routeCurrent()) {
              tracedFirstVisible = true;
              trace.markNextRaster('story_first_visible',
                  current: () => routeCurrent() && sheetRoute?.isActive == true);
            }
            return child!;
          },
        );
      },
    );
    unawaited(navigator.push(sheetRoute));
    if (!routeCurrent()) check();
    unawaited(sheetRoute.completed.whenComplete(() {
      removeClose?.call();
      coverChanges.removeListener(check);
      scope?.removeListener(check);
      reader?.accessChanges.removeListener(check);
      content?.removeListener(check);
      contentCaps?.removeListener(check);
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

  List<StudentHomePromoPlacement> _promoPlacements() {
    if (!_cachedContentAllowed) return const [];
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
        if (_showPromoInCurrentVisit(card))
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

  bool _showPromoInCurrentVisit(ManagedContentCard card) {
    if (_promoReady(card)) {
      _shownPromosThisVisit.add(card.id);
      return true;
    }
    // An existing authorized card can show its own image fallback at the same
    // height while a replacement cover loads. New cards still wait for bytes.
    return _shownPromosThisVisit.contains(card.id) &&
        _promoAssetIdentities[card.id] == _promoIdentity(card);
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
    final scope = _authScope;
    final owner = _loadAuthScope;
    final userId = _service.currentUserId;
    bool stillOnline() =>
        mounted && widget.cachedReader == null && modeRevision == _modeRevision &&
        userId == _service.currentUserId && identical(scope, _authScope) &&
        (scope == null || (owner != null && scope.isCurrent(owner)));
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
      await _refreshPromo(stillOnline);
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
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(16)),
              child: Image(
                image: AssetImage('assets/icons/launcher_icon.png'),
                width: 56,
                height: 56,
              ),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Подготавливаем главную…')),
          ],
        ),
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
