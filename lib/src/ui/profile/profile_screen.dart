import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/router_observer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:collection/collection.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/friends/my_friends_screen.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';

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
    });
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
    } catch (e) {
      debugPrint('[Profile] refreshFromServer error: $e');
    }
  }

  // ===== logout =====
  Future<void> _logout() async {
    try {
      await PushNotificationService.instance.onLogout();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('loggedIn');
      await prefs.remove('user');
      await _sb.auth.signOut();
      if (!mounted) return;
      context.go('/login');
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
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, headerTopPad, 16, 24),
            children: [
              _Header(
                fullName: fullName.isEmpty ? 'Без имени' : fullName,
                university: uni,
                groupName: group,
                status: status,
                avatarUrl: avatar,
              ),
              const SizedBox(height: 16),

              // Две кнопки: Сообщения / Друзья
              _ActionsRow(
                messagesBadge: _unreadTotal,
                requestsBadge: _requestsCount,
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

              const SizedBox(height: 20),

              const _SectionTitle('Лента'),
              const SizedBox(height: 10),
              _FeedCarousel(
                items: _demoFeed,
                onTapItem: (it) => _openFeedItem(context, it),
              ),
              const SizedBox(height: 20),

              const _SectionTitle('Учёба'),
              const SizedBox(height: 10),
              _ExamsBanner(onTap: () => context.push('/exams')),
              const SizedBox(height: 12),
              _PersonalDiaryBanner(onTap: () => context.push('/my-diary')),
              const SizedBox(height: 12),
              _NotificationsBanner(
                onTap: () => context.push('/notification-settings'),
              ),
              const SizedBox(height: 12),
              _MapBanner(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const MapSpbgasuScreen(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFeedItem(BuildContext context, FeedItem item) async {
    if (item.url != null) {
      final uri = Uri.parse(item.url!);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть: ${item.url}')),
        );
      }
      return;
    }
    if (item.route != null) {
      if (context.mounted) context.push(item.route!);
      return;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Элемент: ${item.title}')),
      );
    }
  }
}

// =================== Вспомогательные виджеты (без изменений по сути) ===================

class _Header extends StatelessWidget {
  final String fullName;
  final String university;
  final String groupName;
  final String status;
  final String? avatarUrl;

  const _Header({
    required this.fullName,
    required this.university,
    required this.groupName,
    required this.status,
    required this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    ImageProvider? avatarProvider;
    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      avatarProvider = NetworkImage(avatarUrl!);
    }

    return Column(
      children: [
        CircleAvatar(
          radius: 44,
          backgroundColor: const Color(0xFFDCD0FA),
          backgroundImage: avatarProvider,
          child: avatarProvider == null
              ? const Icon(Icons.person, size: 44)
              : null,
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              fullName,
              style: text.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800, color: Colors.black),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.verified, size: 18, color: Color(0xFF7C63D8)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          university.isEmpty && groupName.isEmpty
              ? 'Данные профиля не заполнены'
              : [
                  if (university.isNotEmpty) university,
                  if (groupName.isNotEmpty) 'группа $groupName',
                ].join(', '),
          style: text.bodyMedium?.copyWith(color: Colors.black),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          status.isEmpty ? 'Статус не указан' : status,
          style: text.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

const double _kActionHeight = 44;
const double _kActionRadius = 16;

class _ActionsRow extends StatelessWidget {
  final int messagesBadge;
  final int requestsBadge;
  final VoidCallback? onMessagesTap;
  final VoidCallback? onFriendsTap;

  const _ActionsRow({
    required this.messagesBadge,
    required this.requestsBadge,
    this.onMessagesTap,
    this.onFriendsTap,
  });

  @override
  Widget build(BuildContext context) {
    debugPrint(
        '${DateTime.now().toIso8601String().substring(11, 23)} [ActionsRow] build messages=$messagesBadge requests=$requestsBadge');
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Row(
          children: [
            Expanded(
              flex: 11,
              child: _QuickActionButton(
                label: 'Сообщения',
                icon: Icons.chat_bubble_outline,
                badge: 0, // внешний бейдж рисуется поверх ряда
                gradient: const [Color(0xFFEDE7F6), Color(0xFFD9CCF5)],
                onTap: onMessagesTap,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 10,
              child: _QuickActionButton(
                label: 'Друзья',
                icon: Icons.group_outlined,
                badge: 0, // внешний бейдж рисуется поверх ряда
                gradient: const [Color(0xFFD6F5EE), Color(0xFFC2ECE4)],
                onTap: onFriendsTap,
              ),
            ),
          ],
        ),
        if (messagesBadge > 0)
          Positioned(
            left: 0,
            top: -10,
            child: _EdgeBadge(
              key: ValueKey('msg_${messagesBadge}'),
              text: messagesBadge > 99 ? '99+' : messagesBadge.toString(),
              isLeft: true,
            ),
          ),
        if (requestsBadge > 0)
          Positioned(
            right: 0,
            top: -10,
            child: _EdgeBadge(
              key: ValueKey('req_${requestsBadge}'),
              text: requestsBadge > 9 ? '9+' : requestsBadge.toString(),
              isLeft: false,
            ),
          ),
      ],
    );
  }
}

class _EdgeBadge extends StatelessWidget {
  final String text;
  final bool isLeft;

  const _EdgeBadge({super.key, required this.text, required this.isLeft});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black87),
      ),
    );
  }
}
// (extension для бейджа удален, чтобы виджет пересобирался корректно)

class _QuickActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final int badge;
  final List<Color> gradient;
  final VoidCallback? onTap;

  const _QuickActionButton({
    required this.label,
    required this.icon,
    required this.badge,
    required this.gradient,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = BoxDecoration(
      gradient: LinearGradient(
        colors: gradient,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      borderRadius: BorderRadius.circular(_kActionRadius),
      boxShadow: [
        BoxShadow(
          color: gradient.last.withValues(alpha: .18),
          blurRadius: 16,
          offset: const Offset(0, 8),
        ),
      ],
    );

    Widget? badgeWidget;
    if (badge > 0) {
      final s = badge > 99 ? '99+' : '$badge';
      badgeWidget = Positioned(
        top: 6,
        left: 6,
        child: Container(
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .85),
            borderRadius: BorderRadius.circular(11),
            boxShadow: const [
              BoxShadow(
                  color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            s,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Colors.black87,
            ),
          ),
        ),
      );
    }

    return Container(
      height: _kActionHeight,
      decoration: bg,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(_kActionRadius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_kActionRadius),
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(icon, size: 22, color: Colors.black87),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.black,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (badgeWidget != null) badgeWidget,
            ],
          ),
        ),
      ),
    );
  }
}

// ===== feed/carousel =====

class FeedItem {
  final String title;
  final String subtitle;
  final List<Color> gradient;
  final String? route;
  final String? url;

  FeedItem({
    required this.title,
    required this.subtitle,
    required this.gradient,
    this.route,
    this.url,
  });
}

final List<FeedItem> _demoFeed = [
  FeedItem(
    title: 'О нас',
    subtitle: 'Команда Студент Платформ',
    gradient: [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
    url: 'https://example.com/about',
  ),
  FeedItem(
    title: 'Расписание занятий',
    subtitle: 'Твое расписание всегда под рукой',
    gradient: [Color(0xFFC5EFE5), Color(0xFFAEE3D8)],
    route: '/schedule',
  ),
  FeedItem(
    title: 'Скидки для студентов',
    subtitle: 'Обновляем лучшие предложения',
    gradient: [Color(0xFFFFE5B9), Color(0xFFDCD0FA)],
    url: 'https://example.com/discounts',
  ),
];

class _FeedCarousel extends StatefulWidget {
  final List<FeedItem> items;
  final void Function(FeedItem) onTapItem;
  const _FeedCarousel({required this.items, required this.onTapItem});

  @override
  State<_FeedCarousel> createState() => _FeedCarouselState();
}

class _FeedCarouselState extends State<_FeedCarousel> {
  final PageController _controller = PageController(viewportFraction: .92);
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;

    return Column(
      children: [
        SizedBox(
          height: 160,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (i) => setState(() => _index = i),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final it = items[i];
              return GestureDetector(
                onTap: () => widget.onTapItem(it),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(
                      colors: it.gradient,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: it.gradient.last.withValues(alpha: .35),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 16,
                        right: 16,
                        bottom: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              it.subtitle,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 13.5,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        _DotsIndicator(length: items.length, index: _index),
      ],
    );
  }
}

class _DotsIndicator extends StatelessWidget {
  final int length;
  final int index;
  const _DotsIndicator({required this.length, required this.index});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 6,
          width: active ? 18 : 6,
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade400,
            borderRadius: BorderRadius.circular(12),
          ),
        );
      }),
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

class _ExamsBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _ExamsBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = const [
      Color(0xFFDCD0FA),
      Color(0xFFC9B8F3),
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
            const Icon(Icons.school_outlined,
                size: 24, color: Color(0xFF7C63D8)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Текущий семестр',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Зачёты, экзамены и учебный план',
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

class _NotificationsBanner extends StatelessWidget {
  final VoidCallback onTap;
  const _NotificationsBanner({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = const [
      Color(0xFFDCD0FA),
      Color(0xFFC9B8F3),
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
            const Icon(Icons.notifications_none_rounded,
                size: 24, color: Color(0xFF7C63D8)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Уведомления',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Сообщения, друзья, задания и расписание',
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
