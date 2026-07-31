import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/router_observer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:collection/collection.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:student_ui/student_ui.dart';

import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/services/auth_service.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/friends/my_friends_screen.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:student_platform/src/ui/content/content_nav_executor.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:student_platform/src/ui/profile/profile_feed_service.dart';
import 'package:student_platform/src/ui/profile/student_points_service.dart';
import 'package:student_platform/src/ui/profile/my_reviews_screen.dart';

class ProfileScreen extends StatefulWidget {
  final ValueListenable<bool>? activeListenable;
  const ProfileScreen({super.key, this.activeListenable});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with WidgetsBindingObserver, RouteAware {
  // ----- state -----
  Map<String, dynamic>? _user;
  bool _loading = true;

  // ----- deps -----
  final SupabaseClient _sb = Supabase.instance.client;
  final _repo = SupabaseLearningRepository();
  final ProfileFeedService _feedService = ProfileFeedService();
  final ContentMediaService _contentMedia = ContentMediaService();
  ProfileFeedLoadResult _feed =
      const ProfileFeedLoadResult(isDemoFallback: true);
  final StudentPointsService _pointsService = StudentPointsService();
  StudentPointsLoadResult _points =
      const StudentPointsLoadResult(isDemoFallback: true);
  int _pointsLoadGeneration = 0;
  bool _pointsLoadInFlight = false;
  final Set<String> _recordedFeedImpressions = {};
  int _feedLoadGeneration = 0;
  int _feedMediaGeneration = 0;
  bool _feedLoadInFlight = false;

  // ----- badges -----
  int _friendsCount = 0; // (сейчас не рисуем, но оставил)
  int _requestsCount = 0; // бейдж "Заявки"
  int _unreadTotal = 0; // бейдж "Сообщения"

  // ----- polling -----
  Timer? _pollTimer;
  static const Duration _pollEvery = Duration(seconds: 20);
  static const Duration _chatIdsCacheTtl = Duration(minutes: 3);
  bool _pollInFlight = false;
  bool _repollPending = false;
  DateTime? _lastPollStartedAt;
  Future<void>? _chatIdsPrepareFuture;
  DateTime? _chatIdsPreparedAt;

  // ----- visibility gate -----
  bool _wasVisible = false;

  // chat ids для суммирования unread
  List<String> _chatIds = const [];

  String? get _uid => _sb.auth.currentUser?.id ?? (_user?['id'] as String?);

  // ——— helpers for logs ———
  String _ts() => DateTime.now().toIso8601String().substring(11, 23);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // слушаем активность от родителя
    widget.activeListenable?.addListener(_onActiveChanged);
    // стартуем после первого кадра, чтобы исключить странности при построении
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('${_ts()} [Profile] initState -> postFrame boot()');
      _boot(); // без автозапуска таймера
      unawaited(_loadFeed());
      unawaited(_loadPoints());
    });
  }

  Future<void> _loadPoints() async {
    if (_pointsLoadInFlight) return;
    final generation = ++_pointsLoadGeneration;
    _pointsLoadInFlight = true;
    try {
      final next = await _pointsService.load();
      if (!mounted || generation != _pointsLoadGeneration) return;
      setState(() => _points = next);
    } catch (error) {
      debugPrint('[profile] points load failed: $error');
      if (!mounted || generation != _pointsLoadGeneration) return;
      setState(
        () => _points = const StudentPointsLoadResult(loadError: true),
      );
    } finally {
      if (generation == _pointsLoadGeneration) {
        _pointsLoadInFlight = false;
      }
    }
  }

  Future<void> _loadFeed() async {
    if (_feedLoadInFlight) return;
    final generation = ++_feedLoadGeneration;
    _feedLoadInFlight = true;
    try {
      final cached = await _feedService.loadCached();
      if (!mounted || generation != _feedLoadGeneration) return;
      if (cached.cards.isNotEmpty) {
        setState(() => _feed = cached);
        unawaited(_hydrateFeedMedia(cached));
      }
      try {
        final next = await _feedService.load();
        if (!mounted || generation != _feedLoadGeneration) return;
        setState(() => _feed = next);
        unawaited(_hydrateFeedMedia(next));
      } catch (error) {
        debugPrint('[profile] feed load failed: $error');
        if (!mounted || generation != _feedLoadGeneration) return;
        if (_feed.cards.isNotEmpty) {
          setState(
            () => _feed = ProfileFeedLoadResult(
              cards: _feed.cards,
              loadError: true,
            ),
          );
        } else {
          setState(
            () => _feed = const ProfileFeedLoadResult(loadError: true),
          );
        }
      }
    } finally {
      if (generation == _feedLoadGeneration) {
        _feedLoadInFlight = false;
      }
    }
  }

  Future<void> _hydrateFeedMedia(ProfileFeedLoadResult feed) async {
    final generation = ++_feedMediaGeneration;
    if (feed.hideFeed || feed.isDemoFallback || feed.cards.isEmpty) return;

    // Mark image variants as loading until bytes arrive (home promo parity).
    final loadingCards = profileFeedCardsWithImageLoading(feed.cards);
    if (mounted && generation == _feedMediaGeneration) {
      setState(() {
        _feed = ProfileFeedLoadResult(
          cards: loadingCards,
          isDemoFallback: feed.isDemoFallback,
          intentionallyEmpty: feed.intentionallyEmpty,
          loadError: feed.loadError,
          rpcUnavailable: feed.rpcUnavailable,
        );
      });
    }

    final hydrated = <ManagedProfileFeedCard>[];
    for (final card in loadingCards) {
      if (!mounted || generation != _feedMediaGeneration) return;
      final version = '${card.id}|${card.sortOrder}';
      Uint8List? imageBytes = card.imageBytes;
      Uint8List? iconBytes = card.iconBytes;
      final imageId = card.payload.imageAssetId?.trim();
      final iconId = card.payload.iconAssetId?.trim();
      final needsImage = profileFeedCardNeedsImageFetch(card);
      if (needsImage && imageId != null && imageId.isNotEmpty) {
        imageBytes = await _contentMedia.fetchBytes(
          imageId,
          contentVersion: version,
        );
      }
      if ((iconBytes == null || iconBytes.isEmpty) &&
          iconId != null &&
          iconId.isNotEmpty) {
        iconBytes = await _contentMedia.fetchBytes(
          iconId,
          contentVersion: '$version|icon',
        );
      }
      hydrated.add(
        card.copyWith(
          imageBytes: imageBytes,
          iconBytes: iconBytes,
          imageLoading: false,
          clearImageBytes: needsImage &&
              (imageBytes == null || imageBytes.isEmpty),
        ),
      );
    }
    if (!mounted || generation != _feedMediaGeneration) return;
    // Keep last-good if a newer feed load already replaced the set.
    final currentIds = _feed.cards.map((c) => c.id).join('|');
    final sourceIds = feed.cards.map((c) => c.id).join('|');
    if (currentIds != sourceIds && _feed.cards.isNotEmpty) return;
    setState(() {
      _feed = ProfileFeedLoadResult(
        cards: hydrated,
        isDemoFallback: feed.isDemoFallback,
        intentionallyEmpty: feed.intentionallyEmpty,
        loadError: feed.loadError,
        rpcUnavailable: feed.rpcUnavailable,
      );
    });
  }

  void _recordVisibleFeedImpression(ManagedProfileFeedCard card) {
    if (_feed.isDemoFallback || _feed.hideFeed || _feed.showLoadError) return;
    if (card.showDemoBadge || card.id.startsWith('demo-')) return;
    if (!_recordedFeedImpressions.add(card.id)) return;
    unawaited(_feedService.recordEvent(card.id, 'impression'));
  }

  Future<void> _onManagedFeedTap(ManagedProfileFeedCard card) async {
    if (!card.showDemoBadge && !card.id.startsWith('demo-')) {
      await _feedService.recordEvent(card.id, 'click');
    }
    final payload = card.payload;
    final intent = ContentNavResolver.resolve(
      action: payload.action,
      ctaRoute: payload.ctaRoute,
      ctaUrl: payload.ctaUrl,
    );
    if (!mounted) return;
    if (intent is ContentNavNone) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(payload.title)),
      );
      return;
    }
    await const ContentNavExecutor().execute(
      context,
      intent,
      onUnavailable: () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Контент недоступен')),
        );
      },
      onDisabled: () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Действие недоступно')),
        );
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    widget.activeListenable?.removeListener(_onActiveChanged);
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    super.dispose();
  }

  // ===== RouteAware callbacks =====
  @override
  void didPush() {
    debugPrint('${_ts()} [Profile] didPush -> start polling');
    _onActiveChanged();
  }

  @override
  void didPopNext() {
    debugPrint('${_ts()} [Profile] didPopNext -> resume polling');
    _onActiveChanged();
  }

  @override
  void didPushNext() {
    debugPrint('${_ts()} [Profile] didPushNext -> stop polling');
    _stopPolling();
  }

  @override
  void didPop() {
    debugPrint('${_ts()} [Profile] didPop -> stop polling');
    _stopPolling();
  }

  // ===== lifecycle =====
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final active = widget.activeListenable?.value ?? true;
      if (active) {
        debugPrint(
            '${_ts()} [Profile] lifecycle resumed & visible -> start polling');
        // ignore: discarded_futures
        AuthSession.ensureFreshSession(_sb);
        _startPolling();
        // ignore: discarded_futures
        _pollOnce();
        unawaited(_loadFeed());
      } else {
        debugPrint(
            '${_ts()} [Profile] lifecycle resumed but hidden -> keep stopped');
      }
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      debugPrint(
          '${_ts()} [Profile] lifecycle -> paused/inactive (stop polling)');
      _stopPolling();
    }
  }

  // ===== boot =====
  Future<void> _boot() async {
    debugPrint('${_ts()} [Profile] boot start');
    // 1) локальный пользователь (для шапки/группы)
    await _loadLocal();
    // 2) гарантируем валидную сессию
    await _ensureSession();
    if (mounted) setState(() => _loading = false);
    // 3) первый тик — только если вкладка активна. Не блокируем профиль
    // подготовкой chat ids: unread_total считает серверный RPC.
    if (mounted && (widget.activeListenable?.value ?? true)) {
      await _pollOnce();
    }
    debugPrint('${_ts()} [Profile] boot done');
  }

  // === явное управление из родителя ===
  void _onActiveChanged() {
    final active = widget.activeListenable?.value ?? true;
    if (active) {
      debugPrint('${_ts()} [Profile] active=true -> start polling');
      _startPolling();
      // ignore: discarded_futures
      _pollOnce();
      unawaited(_loadFeed());
      unawaited(_loadPoints());
    } else {
      debugPrint('${_ts()} [Profile] active=false -> stop polling');
      _stopPolling();
    }
  }

  // ===== visibility helpers =====
  bool _isActuallyVisible() {
    // Если есть PageRoute — проверяем, что текущий
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      if (!route.isCurrent) return false;
    }
    // Если экран в Offstage(true) — он спрятан (типично для IndexedStack)
    final offstage = context.findAncestorWidgetOfExactType<Offstage>();
    if (offstage != null && offstage.offstage) return false;
    // Рендер привязан и имеет размер
    final ro = context.findRenderObject();
    if (ro is RenderBox) {
      return ro.attached && ro.hasSize && ro.size.longestSide > 0;
    }
    return mounted;
  }

  Future<void> _loadLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString('user');
      if (s != null && s.isNotEmpty) {
        _user = jsonDecode(s) as Map<String, dynamic>;
      }
    } catch (_) {}
  }

  // ===== session keep-alive (без realtime) =====
  Future<void> _ensureSession() async {
    try {
      await AuthSession.ensureFreshSession(_sb);
    } catch (e) {
      debugPrint('${_ts()} [Profile] ensureSession error: $e');
    }
  }

  // ===== polling =====
  void _startPolling() {
    if (_pollTimer != null) return; // уже запущен
    _pollTimer = Timer.periodic(_pollEvery, (_) {
      debugPrint('${_ts()} [Profile] tick');
      // ignore: discarded_futures
      _pollOnce();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollOnce() async {
    final now = DateTime.now();
    final lastStartedAt = _lastPollStartedAt;
    if (lastStartedAt != null &&
        now.difference(lastStartedAt) < const Duration(seconds: 2)) {
      return;
    }
    _lastPollStartedAt = now;

    if (_pollInFlight) {
      _repollPending = true;
      return;
    }
    _pollInFlight = true;
    debugPrint('${_ts()} [Profile] pollOnce begin');
    try {
      // не обновляем сессию на каждом тике — это медленно

      final id = _uid;
      if (!mounted || id == null || id.isEmpty) {
        _applyZeros();
        return;
      }

      // параллельно тянем счётчики друзей/заявок и суммарные непрочитанные
      final friendsAndReqF = _fetchFriendsAndRequests(id);
      final unreadF = _fetchUnreadTotal();

      final fr = await friendsAndReqF;
      final ut = await unreadF;

      if (!mounted) return;

      final (fc, rc) = fr;
      final newFriends = fc ?? 0;
      final newReq = rc ?? 0;
      final newUnread = ut ?? 0;
      if (newFriends != _friendsCount ||
          newReq != _requestsCount ||
          newUnread != _unreadTotal) {
        setState(() {
          _friendsCount = newFriends;
          _requestsCount = newReq;
          _unreadTotal = newUnread;
        });
      }
    } catch (e) {
      debugPrint('${_ts()} [Profile] pollOnce error: $e');
    } finally {
      debugPrint('${_ts()} [Profile] pollOnce end');
      _pollInFlight = false;
      if (_repollPending) {
        _repollPending = false;
        // ignore: discarded_futures
        _pollOnce();
      }
    }
  }

  void _applyZeros() {
    setState(() {
      _friendsCount = 0;
      _requestsCount = 0;
      _unreadTotal = 0;
    });
  }

  // безопасное преобразование значений из RPC к int
  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  // friends + requests via RPC
  Future<(int?, int?)> _fetchFriendsAndRequests(String userId) async {
    try {
      final res = await _sb.rpc('get_profile_counters',
          params: {'p_uid': userId}).timeout(const Duration(seconds: 30));
      debugPrint(
          '${_ts()} [Counters] rpc=get_profile_counters -> ${res.runtimeType} $res');

      int friends = 0;
      int requests = 0;

      if (res is List && res.isNotEmpty) {
        final m = Map<String, dynamic>.from(res.first as Map);
        friends = _asInt(m['friends_count']);
        requests = _asInt(m['requests_count']);
      } else if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        friends = _asInt(m['friends_count']);
        requests = _asInt(m['requests_count']);
      }

      return (friends, requests);
    } catch (e) {
      debugPrint('${_ts()} [Counters] error: $e');
      return (null, null);
    }
  }

  // unread (сумма по всем main chat’ам)
  Future<int?> _fetchUnreadTotal() async {
    try {
      final res =
          await _sb.rpc('unread_total').timeout(const Duration(seconds: 30));
      if (res is int) return res;
      if (res is num) return res.toInt();
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        final key = m.keys.firstWhere(
          (k) => k.contains('unread'),
          orElse: () => m.keys.first,
        );
        return _asInt(m[key]);
      }
      if (res is List && res.isNotEmpty) {
        final m = Map<String, dynamic>.from(res.first as Map);
        final key = m.keys.firstWhere(
          (k) => k.contains('unread'),
          orElse: () => m.keys.first,
        );
        return _asInt(m[key]);
      }
      return 0;
    } catch (e) {
      debugPrint('${_ts()} [UnreadTotal] error: $e');
      return null;
    }
  }

  // realtime disabled — polling only

  // подготовка chat ids (разово и при смене группы)
  Future<void> _ensureChatIdsPrepared() async {
    final preparedAt = _chatIdsPreparedAt;
    if (_chatIds.isNotEmpty &&
        preparedAt != null &&
        DateTime.now().difference(preparedAt) < _chatIdsCacheTtl) {
      return;
    }

    final inFlight = _chatIdsPrepareFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = _prepareChatIds();
    _chatIdsPrepareFuture = future;
    try {
      await future;
    } finally {
      if (identical(_chatIdsPrepareFuture, future)) {
        _chatIdsPrepareFuture = null;
      }
    }
  }

  Future<void> _prepareChatIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('user');
      String group = '';
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        group = (m['group_name'] ?? '') as String;
      }
      if (group.isEmpty) {
        _chatIds = const [];
        _chatIdsPreparedAt = DateTime.now();
        return;
      }

      debugPrint('${_ts()} [Profile] loadTeams("$group")');
      final teams = await _repo.loadTeams(group);
      final ids = <String>[];
      for (final t in teams) {
        try {
          final chatId = await _repo
              .getMainChatId(t.id)
              .timeout(const Duration(seconds: 20));
          if (chatId.isNotEmpty) ids.add(chatId);
        } catch (e) {
          debugPrint('${_ts()} [Profile] getMainChatId skipped: $e');
        }
      }
      final changed = const ListEquality().equals(_chatIds, ids) == false;
      _chatIds = ids;
      _chatIdsPreparedAt = DateTime.now();
      debugPrint(
          '${_ts()} [Profile] chatIds prepared: ${_chatIds.length} -> $_chatIds (changed=$changed)');
    } catch (e) {
      debugPrint('${_ts()} [Profile] ensureChatIdsPrepared error: $e');
      if (_chatIds.isEmpty) {
        _chatIds = const [];
      }
    }
  }

  // ===== ручной refresh =====
  Future<void> _refreshFromServer() async {
    try {
      await _ensureSession();

      final id = _uid ?? _user?['id'] as String?;
      if (id == null || id.isEmpty) return;

      final fresh = await _sb
          .from('users')
          .select(
              'id, login, name, surname, university, group_name, avatar_url, status')
          .eq('id', id)
          .maybeSingle();

      if (fresh != null) {
        final mapFresh = Map<String, dynamic>.from(fresh as Map);
        _user = mapFresh;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user', jsonEncode(mapFresh));
        setState(() {}); // обновим шапку
        _chatIds = const [];
        _chatIdsPreparedAt = null;
        await _ensureChatIdsPrepared();
      }

      await _pollOnce(); // подтянуть бейджи сразу
      await _loadFeed();
      await _loadPoints();
    } catch (e) {
      debugPrint('[Profile] refreshFromServer error: $e');
    }
  }

  // ===== logout =====
  Future<void> _logout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('loggedIn');
      await prefs.remove('user');
      // Centralized path clears news + profile-feed caches (Stage 15.2/15.3).
      if (!mounted) return;
      await AuthService.signOut(context);
    } catch (_) {}
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    // Жёсткая заслонка видимости: включаем/выключаем опрос в зависимости от видимости
    final nowVisible = _isActuallyVisible();
    if (nowVisible != _wasVisible) {
      _wasVisible = nowVisible;
      if (nowVisible) {
        debugPrint('${_ts()} [Profile] visible(true) -> start polling');
        _startPolling();
        // ignore: discarded_futures
        _pollOnce();
      } else {
        debugPrint('${_ts()} [Profile] visible(false) -> stop polling');
        _stopPolling();
      }
    }
    debugPrint(
        '${_ts()} [Profile] build ui -> friends=$_friendsCount req=$_requestsCount unread=$_unreadTotal loading=$_loading');
    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final u = _user;
    final first = (u?['name'] ?? '') as String;
    final last = (u?['surname'] ?? '') as String;
    final uni = (u?['university'] ?? '') as String;
    final group = (u?['group_name'] ?? '') as String;
    final status = (u?['status'] ?? '') as String;
    final avatar = (u?['avatar_url'] as String?)?.trim();
    final fullName = [first, last].where((s) => s.isNotEmpty).join(' ').trim();

    // Поднять шапку профиля ~28px: аватар слегка заходит в центр AppBar.
    final headerTopPad =
        MediaQuery.paddingOf(context).top + kToolbarHeight - 16;

    return Scaffold(
      backgroundColor: const Color(0xFFFAF8FC),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarBrightness: Brightness.light,
          statusBarIconBrightness: Brightness.dark,
        ),
        leading: IconButton(
          tooltip: 'Редактировать',
          icon: const Icon(Icons.tune),
          onPressed: () async {
            await context.push('/edit-profile');
            await _loadLocal();
            await _ensureSession();
            await _ensureChatIdsPrepared();
            await _pollOnce(); // форс-опрос после возвращения
          },
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshFromServer,
          ),
          IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: Theme(
        data: Theme.of(context).copyWith(
          textTheme: Theme.of(context)
              .textTheme
              .apply(bodyColor: Colors.black, displayColor: Colors.black),
        ),
        child: RefreshIndicator(
          onRefresh: _refreshFromServer,
          child: StudentProfileScreenPreview(
            padding: EdgeInsets.fromLTRB(16, headerTopPad, 16, 24),
            displayName: fullName.isEmpty ? 'Без имени' : fullName,
            groupLabel: group,
            universityLabel: uni.isEmpty ? null : uni,
            statusLabel: status.isEmpty ? null : status,
            avatarUrl: avatar,
            messagesBadge: _unreadTotal,
            friendsBadge: _requestsCount,
            pointsChip: (!_points.hidePoints || _points.showLoadError)
                ? (_points.showLoadError
                    ? Text(
                        'Баллы временно недоступны',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF6B7280),
                            ),
                        textAlign: TextAlign.center,
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          StudentPointsSummaryChip(
                            summary: _points.displaySummary,
                            showDemoBadge: _points.isDemoFallback &&
                                _points.rpcUnavailable,
                          ),
                          if (_points.displaySummary.entries.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              _formatLatestPointsEntry(
                                _points.displaySummary.entries.first,
                              ),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: const Color(0xFF6B7280),
                                  ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ],
                      ))
                : null,
            feedCards: _feed.hideFeed ? const [] : _feed.displayCards,
            feedLoadError: _feed.showLoadError,
            onFeedRetry: () => unawaited(_loadFeed()),
            onFeedTap: _onManagedFeedTap,
            onFeedVisible: _recordVisibleFeedImpression,
            onDiaryTap: () => context.push('/my-diary'),
            onMapTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const MapSpbgasuScreen(),
              ),
            ),
            onReviewsTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyReviewsScreen()),
              );
            },
            onMessagesTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyChatsScreen()),
              );
              if (!mounted) return;
              await _ensureSession();
              await _pollOnce();
            },
            onFriendsTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyFriendsScreen()),
              );
              if (!mounted) return;
              await _ensureSession();
              await _pollOnce();
            },
          ),
        ),
      ),
    );
  }

  String _formatLatestPointsEntry(StudentPointsEntry entry) {
    final label = entry.reasonCode.labelRu;
    return 'Последнее: ${entry.signedLabel} · $label';
  }
}

// ===== banners =====

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

/// Study shortcuts on the profile tab (kept public for focused widget tests).
class ProfileStudySection extends StatelessWidget {
  final VoidCallback onDiaryTap;
  final VoidCallback onMapTap;

  const ProfileStudySection({
    super.key,
    required this.onDiaryTap,
    required this.onMapTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Учёба'),
        const SizedBox(height: 14),
        _PersonalDiaryBanner(onTap: onDiaryTap),
        const SizedBox(height: 14),
        _MapBanner(onTap: onMapTap),
      ],
    );
  }
}

class _MapBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _MapBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xFFC5EFE5),
      const Color(0xFFAEE3D8),
    ];
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight),
          boxShadow: [
            BoxShadow(
                color: colors.last.withValues(alpha: .25),
                blurRadius: 16,
                offset: const Offset(0, 10))
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.map_outlined, size: 24, color: Color(0xFF2F9D84)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Карта СПБГАСУ',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

class _PersonalDiaryBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _PersonalDiaryBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = const [
      Color(0xFFDCD0FA),
      Color(0xFFC5EFE5),
    ];
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: colors.last.withValues(alpha: .25),
              blurRadius: 16,
              offset: const Offset(0, 10),
            )
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.menu_book_outlined,
                size: 24, color: Color(0xFF7C63D8)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Мой дневник',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Записи, конспекты и файлы по предметам текущего семестра',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.black54),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

// ===== map screen =====

class MapSpbgasuScreen extends StatefulWidget {
  const MapSpbgasuScreen({super.key});

  @override
  State<MapSpbgasuScreen> createState() => _MapSpbgasuScreenState();
}

class _MapSpbgasuScreenState extends State<MapSpbgasuScreen> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            _controller.runJavaScript("""
              document.querySelector('header')?.style.display='none';
              document.querySelector('footer')?.style.display='none';
            """);
          },
        ),
      )
      ..loadRequest(Uri.parse('https://map.spbgasu.ru/'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Карта СПБГАСУ')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
