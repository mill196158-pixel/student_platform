import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/router_observer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:student_ui/student_ui.dart';

import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/legacy_user_cache.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/services/auth_service.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/friends/my_friends_screen.dart';
import 'package:student_platform/src/ui/content/content_nav_executor.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:student_platform/src/ui/profile/profile_feed_service.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';
import 'package:student_platform/src/ui/profile/profile_card_media_loader.dart';
import 'package:student_platform/src/ui/profile/profile_avatar_image.dart';
import 'package:student_platform/src/ui/profile/my_reviews_screen.dart';

class ProfileScreen extends StatefulWidget {
  final ValueListenable<bool>? activeListenable;
  const ProfileScreen(
      {super.key,
      this.activeListenable,
      this.cachedReader,
      this.cachedChats,
      this.cachedCapabilities});
  final CachedHomeScheduleReader? cachedReader;
  final ProjectChatServerCache? cachedChats;
  final SessionCapabilities? cachedCapabilities;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with WidgetsBindingObserver, RouteAware {
  // ----- state -----
  Map<String, dynamic>? _user;
  bool _loading = true;
  bool _cachedUnavailable = false;
  int _cachedProfileGeneration = 0;
  Uint8List? _cachedAvatar;
  ImageProvider? _onlineAvatar;
  String? _onlineOwner;
  int _onlineProfileGeneration = 0;
  int _headerRevision = 0;
  AuthSessionScope? _profileScope;
  int? _scopeGeneration;
  Future<void>? _localHeader;
  StreamSubscription<AuthState>? _authChanges;
  bool _boundaryInvalidated = false;
  final _cachedBoundaryEnd = Completer<void>();
  bool get _cacheOnly =>
      widget.cachedReader != null ||
      widget.cachedChats != null ||
      widget.cachedCapabilities != null;

  // ----- deps -----
  final SupabaseClient _sb = Supabase.instance.client;
  final ProfileFeedService _feedService = ProfileFeedService();
  final ContentMediaService _contentMedia =
      ContentMediaService(persistBytes: true);
  ProfileFeedLoadResult _feed =
      const ProfileFeedLoadResult(intentionallyEmpty: true);
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
  bool _pollInFlight = false;
  bool _repollPending = false;
  DateTime? _lastPollStartedAt;

  // ----- visibility gate -----
  bool _wasVisible = false;
  bool _editingProfile = false;

  // chat ids для суммирования unread

  String? get _uid => _sb.auth.currentUser?.id;

  // ——— helpers for logs ———
  String _ts() => DateTime.now().toIso8601String().substring(11, 23);

  @override
  void initState() {
    super.initState();
    if (_cacheOnly) {
      widget.cachedReader?.accessChanges.addListener(_onCachedAccessChanged);
      CachedHomeScheduleReader.homeRefreshFor(widget.cachedReader)
          ?.addListener(_onCachedProfileRefresh);
      unawaited(_loadCachedProfile());
      return;
    }
    _onlineOwner = _sb.auth.currentUser?.id;
    _authChanges =
        _sb.auth.onAuthStateChange.listen((_) => _onOnlineOwnerChanged());
    WidgetsBinding.instance.addObserver(this);
    // слушаем активность от родителя
    widget.activeListenable?.addListener(_onActiveChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _cacheOnly || _boundaryInvalidated) return;
      unawaited(_warmLocalHeader());
      _onActiveChanged();
    });
  }

  Future<void> _loadFeed() async {
    final owner = _onlineOwner;
    final ownerGeneration = _onlineProfileGeneration;
    if (owner == null || !_isOnlineProfileCurrent(owner, ownerGeneration)) return;
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
        if (_cacheOnly ||
            _boundaryInvalidated ||
            generation != _feedLoadGeneration) return;
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
    final mediaUser = _sb.auth.currentUser?.id;
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

    final hydrated = List<ManagedProfileFeedCard>.from(loadingCards);
    void publish() {
      if (!mounted ||
          generation != _feedMediaGeneration ||
          _sb.auth.currentUser?.id != mediaUser) return;
      // Keep last-good if a newer feed load already replaced the set.
      final currentIds = _feed.cards.map((c) => c.id).join('|');
      final sourceIds = feed.cards.map((c) => c.id).join('|');
      if (currentIds != sourceIds && _feed.cards.isNotEmpty) return;
      setState(() {
        _feed = ProfileFeedLoadResult(
          cards: List.of(hydrated),
          isDemoFallback: feed.isDemoFallback,
          intentionallyEmpty: feed.intentionallyEmpty,
          loadError: feed.loadError,
          rpcUnavailable: feed.rpcUnavailable,
        );
      });
    }

    Future<void> hydrate(int index) async {
      final card = loadingCards[index];
      if (!mounted ||
          generation != _feedMediaGeneration ||
          _sb.auth.currentUser?.id != mediaUser) return;
      await hydrateProfileCardMedia(card,
          fetch: (id, version) =>
              _contentMedia.fetchBytes(id, contentVersion: version),
          onUpdate: (updated) {
            hydrated[index] = updated;
            publish();
          });
    }

    for (var start = 0; start < loadingCards.length; start += 2) {
      await Future.wait([
        for (var i = start; i < loadingCards.length && i < start + 2; i++)
          hydrate(i),
      ]);
    }
  }

  void _recordVisibleFeedImpression(ManagedProfileFeedCard card) {
    if (_cacheOnly || _boundaryInvalidated || !mounted) return;
    if (!mounted ||
        !(widget.activeListenable?.value ?? true) ||
        ModalRoute.of(context)?.isCurrent == false) return;
    if (_feed.isDemoFallback || _feed.hideFeed || _feed.showLoadError) return;
    if (card.showDemoBadge || card.id.startsWith('demo-')) return;
    if (!_recordedFeedImpressions.add(card.id)) return;
    unawaited(_feedService.recordEvent(card.id, 'impression'));
  }

  Future<void> _onManagedFeedTap(ManagedProfileFeedCard card) async {
    if (_cacheOnly || _boundaryInvalidated || !mounted) return;
    if (!card.showDemoBadge && !card.id.startsWith('demo-')) {
      await _feedService.recordEvent(card.id, 'click');
    }
    if (!mounted || _cacheOnly || _boundaryInvalidated) return;
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
    if (_cacheOnly || _boundaryInvalidated) return;
    _profileScope = AuthSessionScopeHost.maybeOf(context);
    _onOnlineOwnerChanged();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    if (!_cachedBoundaryEnd.isCompleted) _cachedBoundaryEnd.complete();
    widget.cachedReader?.accessChanges.removeListener(_onCachedAccessChanged);
    CachedHomeScheduleReader.homeRefreshFor(widget.cachedReader)
        ?.removeListener(_onCachedProfileRefresh);
    unawaited(_authChanges?.cancel());
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
    _wasVisible = false;
    _stopPolling();
  }

  @override
  void didPop() {
    debugPrint('${_ts()} [Profile] didPop -> stop polling');
    _wasVisible = false;
    _stopPolling();
  }

  // ===== lifecycle =====
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cacheOnly || _boundaryInvalidated) return;
    if (state == AppLifecycleState.resumed) {
      _onActiveChanged();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      debugPrint(
          '${_ts()} [Profile] lifecycle -> paused/inactive (stop polling)');
      _wasVisible = false;
      _stopPolling();
    }
  }

  Future<void> _warmLocalHeader() => _localHeader ??= _loadLocal();

  bool get _isVisible =>
      (widget.activeListenable?.value ?? true) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void _onActiveChanged() {
    if (!mounted || _cacheOnly || _boundaryInvalidated || _editingProfile) return;
    final active = _isVisible;
    if (active == _wasVisible) return;
    _wasVisible = active;
    if (!active) {
      _stopPolling();
      return;
    }
    _startPolling();
    unawaited(_refreshVisibleProfile());
  }

  Future<void> _refreshVisibleProfile() async {
    final owner = _onlineOwner;
    final generation = _onlineProfileGeneration;
    await _warmLocalHeader();
    if (owner == null || !_isOnlineProfileCurrent(owner, generation) ||
        !_wasVisible) return;
    await _refreshFromServer();
  }

  void _onOnlineOwnerChanged() {
    if (!mounted || _cacheOnly || _boundaryInvalidated) return;
    final scope = _profileScope;
    final owner = scope?.logoutFenced == true ? null : _uid;
    final scopeGeneration = scope?.generation;
    if (owner == _onlineOwner && scopeGeneration == _scopeGeneration) return;
    _onlineOwner = owner;
    _scopeGeneration = scopeGeneration;
    _onlineProfileGeneration++;
    _headerRevision++;
    _localHeader = null;
    _lastPollStartedAt = null;
    _feedLoadGeneration++;
    _feedMediaGeneration++;
    _feedLoadInFlight = false;
    _recordedFeedImpressions.clear();
    _stopPolling();
    setState(() {
      _user = null;
      _onlineAvatar = null;
      _feed = const ProfileFeedLoadResult(intentionallyEmpty: true);
      _friendsCount = _requestsCount = _unreadTotal = 0;
      _loading = owner != null;
    });
    if (owner != null) {
      unawaited(_warmLocalHeader());
      if (_wasVisible) {
        _startPolling();
        unawaited(_refreshVisibleProfile());
      }
    }
  }

  bool _isOnlineProfileCurrent(String owner, int generation) =>
      mounted &&
      !_cacheOnly &&
      !_boundaryInvalidated &&
      generation == _onlineProfileGeneration &&
      _profileScope?.logoutFenced != true &&
      _profileScope?.generation == _scopeGeneration &&
      _uid == owner;

  HomeSnapshotCache? _profileSnapshots(AuthSessionScope? scope) {
    if (scope == null) return null;
    return HomeSnapshotCache(
      project: SupabaseConfig.url,
      authScope: scope,
      currentUserId: () => scope.capture()?.userId,
      sessionGeneration: () => scope.generation,
      sessionIdentity: scope.capture,
    );
  }

  String _avatarUrl(Map<String, dynamic>? profile) {
    final url = profile?['avatar_url'];
    return url is String ? url.trim() : '';
  }

  Future<bool> _prepareAvatar(ImageProvider provider,
      bool Function() current,
      {Duration budget = const Duration(milliseconds: 850)}) async {
    if (!current()) return false;
    var decoded = true;
    await precacheImage(provider, context, onError: (_, __) => decoded = false)
        .timeout(budget, onTimeout: () {
      decoded = false;
    });
    return decoded && current();
  }

  Future<Uint8List?> _readySavedAvatar(String owner, String url,
      bool Function() current) async {
    if (url.isEmpty || !current()) return null;
    final bytes = await readSavedProfileAvatar(owner, url, isCurrent: current)
        .timeout(const Duration(milliseconds: 850), onTimeout: () => null);
    if (bytes == null || !current()) return null;
    return await _prepareAvatar(MemoryImage(bytes), current) ? bytes : null;
  }

  Future<void> _loadLocal() async {
    final owner = _onlineOwner;
    if (owner == null) return;
    final generation = _onlineProfileGeneration;
    final revision = ++_headerRevision;
    final scope = _profileScope;
    bool current() => _isOnlineProfileCurrent(owner, generation) &&
        revision == _headerRevision;
    try {
      if (scope != null) await scope.ready;
      if (!current() || (scope != null && scope.capture()?.userId != owner)) return;
      final cached = await LegacyUserCache.read(
          currentSession: () => _sb.auth.currentSession);
      if (!current()) return;
      final saved = cached == null
          ? await _profileSnapshots(scope)
              ?.read(owner, HomeSnapshotSection.profile)
              .timeout(const Duration(milliseconds: 850), onTimeout: () => null)
          : null;
      final candidate = cached ?? saved?.items.singleOrNull;
      if (!current() || candidate?['id'] != owner || candidate == null) return;
      final url = _avatarUrl(candidate);
      final provider = _user?['id'] == owner && _avatarUrl(_user) == url &&
              _onlineAvatar != null
          ? _onlineAvatar
          : switch (await _readySavedAvatar(owner, url, current)) {
              final bytes? => MemoryImage(bytes),
              null => null,
            };
      if (!current()) return;
      setState(() {
        _user = candidate;
        _onlineAvatar = provider;
        _loading = false;
      });
    } catch (_) {
      // A malformed or unavailable local profile must not break navigation.
    } finally {
      if (current() && _loading) setState(() => _loading = false);
    }
  }

  // ===== session keep-alive (без realtime) =====
  Future<void> _ensureSession() async {
    final owner = _onlineOwner;
    if (owner == null || !_isOnlineProfileCurrent(owner, _onlineProfileGeneration)) return;
    try {
      await AuthSession.ensureFreshSession(_sb);
    } catch (e) {
      debugPrint('${_ts()} [Profile] ensureSession error: $e');
    }
  }

  // ===== polling =====
  void _startPolling() {
    final owner = _onlineOwner;
    if (owner == null || !_isOnlineProfileCurrent(owner, _onlineProfileGeneration)) return;
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
    final id = _onlineOwner;
    final generation = _onlineProfileGeneration;
    if (id == null || !_isOnlineProfileCurrent(id, generation)) return;
    final now = DateTime.now();
    final lastStartedAt = _lastPollStartedAt;
    if (lastStartedAt != null &&
        now.difference(lastStartedAt) < const Duration(seconds: 2)) {
      return;
    }
    if (_pollInFlight) {
      _repollPending = true;
      return;
    }
    _lastPollStartedAt = now;
    _pollInFlight = true;
    debugPrint('${_ts()} [Profile] pollOnce begin');
    try {
      // не обновляем сессию на каждом тике — это медленно

      // параллельно тянем счётчики друзей/заявок и суммарные непрочитанные
      final friendsAndReqF = _fetchFriendsAndRequests(id);
      final unreadF = _fetchUnreadTotal();

      final fr = await friendsAndReqF;
      final ut = await unreadF;

      if (!_isOnlineProfileCurrent(id, generation)) return;

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

  // ===== ручной refresh =====
  Future<void> _refreshHeader() async {
    final id = _onlineOwner;
    if (id == null) return;
    final generation = _onlineProfileGeneration;
    final revision = ++_headerRevision;
    final scope = _profileScope;
    final owner = scope?.capture();
    bool current() => _isOnlineProfileCurrent(id, generation) &&
        revision == _headerRevision &&
        (scope == null || (owner != null && scope.isCurrent(owner)));
    if (!current()) return;
    final snapshots = _profileSnapshots(scope);
    final snapshotOwner = snapshots?.captureScope(id);
    final fresh = await _sb
        .from('users')
        .select(
            'id, login, name, surname, university, group_name, avatar_url, status')
        .eq('id', id)
        .maybeSingle()
        .timeout(const Duration(seconds: 10));
    if (!current() || fresh == null || fresh['id'] != id) return;
    final url = _avatarUrl(fresh);
    final ImageProvider? existing = _user?['id'] == id && _avatarUrl(_user) == url
        ? _onlineAvatar
        : null;
    final next = existing ?? profileAvatarImage(id, url);
    final preparation = existing != null || next == null
        ? null
        : _prepareAvatar(next, current, budget: const Duration(seconds: 8));
    final ready = await preparation?.then<bool?>((ready) => ready).timeout(
        const Duration(milliseconds: 850), onTimeout: () => null);
    if (!current()) return;
    setState(() {
      _user = fresh;
      _onlineAvatar = existing ?? (ready == true ? next : null);
      _loading = false;
    });
    if (ready == null && preparation != null) {
      unawaited(preparation.then((decoded) {
        if (decoded && current() && _avatarUrl(_user) == url) {
          setState(() => _onlineAvatar = next);
        }
      }));
    }
    if (snapshots != null && snapshotOwner != null) {
      unawaited(snapshots.write(
          scope: snapshotOwner,
          section: HomeSnapshotSection.profile,
          items: [fresh],
          savedAt: DateTime.now()).catchError((Object _) => false));
    }
    final prefs = await SharedPreferences.getInstance();
    if (!current()) return;
    await prefs.setString('user', jsonEncode(fresh));
  }

  Future<void> _refreshFromServer() async {
    final owner = _onlineOwner;
    final generation = _onlineProfileGeneration;
    bool current() => owner != null && _isOnlineProfileCurrent(owner, generation);
    if (!current()) return;
    await _warmLocalHeader();
    if (!current()) return;
    try {
      await _ensureSession();
      if (!current()) return;
      await Future.wait([_refreshHeader(), _pollOnce(), _loadFeed()]);
    } catch (e) {
      debugPrint('[Profile] refreshFromServer error: $e');
    }
  }

  // ===== logout =====
  Future<void> _logout() async {
    try {
      await AuthService.signOut(context);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Не удалось завершить выход. Повторите попытку.'),
      ));
    }
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.cachedReader, widget.cachedReader) &&
        identical(oldWidget.cachedChats, widget.cachedChats) &&
        identical(oldWidget.cachedCapabilities, widget.cachedCapabilities))
      return;
    oldWidget.cachedReader?.accessChanges
        .removeListener(_onCachedAccessChanged);
    CachedHomeScheduleReader.homeRefreshFor(oldWidget.cachedReader)
        ?.removeListener(_onCachedProfileRefresh);
    _boundaryInvalidated = true;
    if (!_cachedBoundaryEnd.isCompleted) _cachedBoundaryEnd.complete();
    _feedLoadGeneration++;
    _feedMediaGeneration++;
    _stopPolling();
    _cachedProfileGeneration++;
    _user = null;
    _cachedAvatar = null;
    _onlineAvatar = null;
    _loading = false;
    _cachedUnavailable = true;
  }

  void _onCachedAccessChanged() {
    if (!mounted || (widget.cachedReader?.canRead ?? false)) return;
    _cachedProfileGeneration++;
    setState(() {
      _user = null;
      _cachedAvatar = null;
      _loading = false;
      _cachedUnavailable = true;
    });
  }

  void _onCachedProfileRefresh() {
    if (mounted) unawaited(_loadCachedProfile());
  }

  Future<void> _loadCachedProfile() async {
    final reader = widget.cachedReader;
    final caps = widget.cachedCapabilities;
    final permit = caps?.capture(SessionCapability.cachedRead);
    if (reader == null ||
        widget.cachedChats == null ||
        caps == null ||
        permit == null ||
        !reader.permitsContent(caps, permit)) {
      if (mounted) {
        setState(() {
          _loading = false;
          _cachedUnavailable = true;
        });
      }
      return;
    }
    final generation = ++_cachedProfileGeneration;
    bool current() =>
        mounted &&
        !_boundaryInvalidated &&
        identical(reader, widget.cachedReader) &&
        identical(caps, widget.cachedCapabilities) &&
        generation == _cachedProfileGeneration &&
        reader.permitsContent(caps, permit);
    try {
      final profile = await reader.readProfile();
      if (!current()) return;
      if (profile == null || profile.id != permit.userId) {
        setState(() {
          _user = null;
          _cachedAvatar = null;
          _loading = false;
          _cachedUnavailable = true;
        });
        return;
      }
      final url = profile.avatarUrl;
      final avatar = _user?['id'] == profile.id && _avatarUrl(_user) == url &&
              _cachedAvatar != null
          ? _cachedAvatar
          : await _readySavedAvatar(profile.id, url, current);
      if (!current()) return;
      setState(() {
        _user = {
          'id': profile.id,
          'name': profile.name,
          'surname': profile.surname,
          'group_name': profile.groupName,
          'university': profile.university,
          'status': profile.status,
          'avatar_url': url,
        };
        _cachedAvatar = avatar;
        _loading = false;
        _cachedUnavailable = false;
      });
    } catch (_) {
      if (current() && _user == null) {
        setState(() {
          _loading = false;
          _cachedUnavailable = true;
        });
      }
    }
  }

  void _explainOfflineProfileAction() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Это действие доступно после подключения к интернету.'),
    ));
  }

  void _openCachedMessages() {
    final cache = widget.cachedChats, caps = widget.cachedCapabilities;
    if (!mounted ||
        _boundaryInvalidated ||
        cache == null ||
        caps == null ||
        !(widget.cachedReader?.canRead ?? false)) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            MyChatsScreen(cachedStore: cache, cachedCapabilities: caps)));
  }

  Widget? _cachedStorageButton() {
    final reader = widget.cachedReader, caps = widget.cachedCapabilities;
    final permit = caps?.capture(SessionCapability.cachedRead);
    if (reader == null || caps == null || permit == null) return null;
    bool current() =>
        mounted &&
        !_cachedBoundaryEnd.isCompleted &&
        identical(widget.cachedReader, reader) &&
        identical(widget.cachedCapabilities, caps) &&
        reader.permitsContent(caps, permit);
    if (!current()) return null;
    return TextButton.icon(
        icon: const Icon(Icons.storage_outlined),
        label: const Text('Данные приложения'),
        onPressed: () {
          if (!current()) return;
          final access = Listenable.merge([caps, reader.accessChanges]);
          Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => FutureBuilder<void>(
                  future: _cachedBoundaryEnd.future,
                  builder: (_, __) => ListenableBuilder(
                      listenable: access,
                      builder: (_, __) => current()
                          ? CacheDiagnosticsScreen(canAccess: current)
                          : Scaffold(
                              appBar: AppBar(),
                              body: const Center(
                                  child: Text('Данные недоступны.')))))));
        });
  }

  Widget _buildCachedProfile(BuildContext context) {
    if (_loading)
      return const Scaffold(
          body: Center(child: ProductLoadingIndicator.page()));
    final canRead =
        !_boundaryInvalidated && (widget.cachedReader?.canRead ?? false);
    final storage = canRead ? _cachedStorageButton() : null;
    if (_cachedUnavailable || _user == null || !canRead) {
      return Scaffold(
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Сохранённый профиль недоступен.'),
        if (storage != null) storage,
        if (canRead &&
            widget.cachedChats != null &&
            widget.cachedCapabilities != null)
          TextButton(
              onPressed: _openCachedMessages, child: const Text('Сообщения')),
        if (canRead)
          TextButton(
              onPressed: _logout, child: const Text('Выйти из аккаунта')),
      ])));
    }
    final u = _user!;
    final name = [u['name'], u['surname']]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(' ');
    return Scaffold(
        appBar: storage == null
            ? null
            : AppBar(
                title: storage,
                centerTitle: true,
                toolbarHeight: MediaQuery.textScalerOf(context).scale(16) > 20
                    ? 76
                    : kToolbarHeight,
              ),
        body: StudentProfileScreenPreview(
          displayName: name.isEmpty ? 'Студент' : name,
          groupLabel: (u['group_name'] ?? '').toString(),
          universityLabel: (u['university'] ?? '').toString(),
          statusLabel: (u['status'] ?? '').toString(),
          avatarBytes: _cachedAvatar,
          onFriendsTap: _explainOfflineProfileAction,
          onDiaryTap: _explainOfflineProfileAction,
          onMapTap: _explainOfflineProfileAction,
          onReviewsTap: _explainOfflineProfileAction,
          padding: EdgeInsets.fromLTRB(
              16,
              storage == null ? MediaQuery.paddingOf(context).top + 16 : 16,
              16,
              24),
          onMessagesTap:
              widget.cachedChats == null || widget.cachedCapabilities == null
                  ? null
                  : _openCachedMessages,
          footer: Column(children: [
            Text(
                'Доступны сохранённый профиль и загруженные чаты. Для остальных действий понадобится интернет.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: const Text('Выйти из аккаунта'),
            ),
          ]),
        ));
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    if (_cacheOnly || _boundaryInvalidated) return _buildCachedProfile(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: ProductLoadingIndicator.page()),
      );
    }

    final u = _profileScope?.logoutFenced != true &&
            _user?['id'] == _uid ? _user : null;
    final first = (u?['name'] ?? '') as String;
    final last = (u?['surname'] ?? '') as String;
    final uni = (u?['university'] ?? '') as String;
    final group = (u?['group_name'] ?? '') as String;
    final status = (u?['status'] ?? '') as String;
    final fullName = [first, last].where((s) => s.isNotEmpty).join(' ').trim();

    // Поднять шапку профиля ~28px: аватар слегка заходит в центр AppBar.
    final headerTopPad =
        MediaQuery.paddingOf(context).top + kToolbarHeight - 16;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: Theme.of(context).appBarTheme.systemOverlayStyle,
        leading: IconButton(
          tooltip: 'Редактировать',
          icon: const Icon(Icons.tune),
          onPressed: () async {
            _editingProfile = true;
            try {
              await context.push('/edit-profile');
              if (mounted) await _loadLocal();
            } finally {
              _editingProfile = false;
              if (mounted) _onActiveChanged();
            }
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
          textTheme: Theme.of(context).textTheme.apply(
              bodyColor: Theme.of(context).colorScheme.onSurface,
              displayColor: Theme.of(context).colorScheme.onSurface),
        ),
        child: RefreshIndicator(
          onRefresh: _refreshFromServer,
          child: StudentProfileScreenPreview(
            padding: EdgeInsets.fromLTRB(16, headerTopPad, 16, 24),
            displayName: fullName.isEmpty ? 'Без имени' : fullName,
            groupLabel: group,
            universityLabel: uni.isEmpty ? null : uni,
            statusLabel: status.isEmpty ? null : status,
            avatarImage: u == null ? null : _onlineAvatar,
            messagesBadge: _unreadTotal,
            friendsBadge: _requestsCount,
            feedCards: _feed.hideFeed
                ? const []
                : readyProfileFeedCards(_feed.displayCards),
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
  static final _mapUrl = Uri.parse('https://map.spbgasu.ru/');
  final _controller = WebViewController();
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_openMap());
  }

  Future<void> _openMap() async {
    if (_failed) setState(() => _failed = false);
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!mounted) return;
      await _controller.setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) _showLoadError();
        },
        onPageFinished: _hideSiteNavigation,
      ));
      if (mounted) await _controller.loadRequest(_mapUrl);
    } on Exception {
      _showLoadError();
    }
  }

  void _showLoadError() {
    if (mounted && !_failed) setState(() => _failed = true);
  }

  Future<void> _hideSiteNavigation(String url) async {
    if (!mounted || _failed || Uri.tryParse(url)?.host != _mapUrl.host) return;
    try {
      await _controller.runJavaScript("""
        document.querySelectorAll('header, footer').forEach(function(element) {
          element.style.display = 'none';
        });
      """);
    } on Exception {
      // The native view can close while the optional page styling is running.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Карта СПБГАСУ')),
      body: Stack(fit: StackFit.expand, children: [
        Offstage(
            offstage: _failed, child: WebViewWidget(controller: _controller)),
        if (_failed)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Не удалось загрузить карту',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('Проверь подключение к интернету.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                OutlinedButton(
                    onPressed: _openMap, child: const Text('Повторить')),
              ]),
            ),
          ),
      ]),
    );
  }
}
