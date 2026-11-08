import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/home/home_content_coordinator.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_ui/student_ui.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Reader implements CachedHomeScheduleReader {
  _Reader(this.caps);
  final SessionCapabilities caps;
  @override
  Listenable get accessChanges => caps;
  @override
  Listenable get refreshChanges => caps;
  @override
  bool get canRead => caps.capture(SessionCapability.cachedRead) != null;
  @override
  bool permitsContent(SessionCapabilities other, CapabilityPermit permit) =>
      canRead && other.permits(permit, SessionCapability.cachedRead);
  @override
  Future<HomeDashboardData> readDashboard({DateTime? date}) async =>
      HomeDashboardData(
          profile: const HomeUserProfile(name: 'QA'),
          scheduleDate: DateTime.now(),
          todayLessons: const [],
          assignments: const [],
          news: const []);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Dashboard implements HomeDashboardService {
  _Dashboard({this.rejectImages = false});
  bool rejectImages;
  int imageValidationCalls = 0;
  @override
  String? get currentUserId => 'qa';
  @override
  Future<List<HomeNewsItem>> validateNewsImages(List<HomeNewsItem> items) async {
    imageValidationCalls++;
    return rejectImages ? items.map((item) => item.copyWith(clearImageBytes: true)).toList() : items;
  }
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _OnlineDashboard extends _Dashboard {
  int writes = 0, reads = 0;
  final markGate = Completer<void>();
  final HomeDashboardData data = HomeDashboardData(
      profile: const HomeUserProfile(name: 'QA'),
      scheduleDate: DateTime.now(),
      todayLessons: const [],
      assignments: const [],
      news: [
        mapPublishedNews({
          'id': 'n',
          'title': 'Online news',
          'body': 'Online text',
          'created_at': '2026-11-06T00:00:00Z'
        })
      ]);
  @override
  Future<HomeDashboardData> load(
          {void Function(HomeDashboardData)? onUpdate,
          HomeDashboardData? previous}) async =>
      data;
  @override
  Future<List<HomeNewsItem>> loadCachedNews() async => [];
  @override
  Future<void> prewarmSchedule(OnlineSideEffectBarrier barrier) async {}
  @override
  Future<void> markNewsSeen(String id, {bool closed = false}) async {
    writes++;
    await markGate.future;
  }

  @override
  Future<Uint8List?> resolveNewsImageBytes(HomeNewsItem item) async {
    reads++;
    return null;
  }
}

class _RefreshDashboard extends _Dashboard {
  _RefreshDashboard(this.first);
  final HomeNewsItem first;
  Completer<void>? loadGate;
  bool returnCached = false;
  @override
  Future<List<HomeNewsItem>> loadCachedNews() async =>
      returnCached ? [first.copyWith(clearImageBytes: true)] : [];
  @override
  Future<HomeDashboardData> load({void Function(HomeDashboardData)? onUpdate,
      HomeDashboardData? previous}) async {
    await loadGate?.future;
    final news = await validateNewsImages(previous?.news ?? [first]);
    return HomeDashboardData(profile: const HomeUserProfile(id: 'qa', name: 'QA'),
        scheduleDate: DateTime.now(), todayLessons: const [],
        assignments: const [], news: news);
  }
  @override
  Future<void> prewarmSchedule(OnlineSideEffectBarrier barrier) async {}
}

class _Promo implements HomePromoService {
  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) async =>
      const HomePromoLoadResult(intentionallyEmpty: true);
  @override
  Future<HomePromoLoadResult> loadCached() async =>
      const HomePromoLoadResult(intentionallyEmpty: true);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Notifications implements AppNotificationsApi {
  @override
  Future<int> unreadCount() async => 0;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Content extends ChangeNotifier implements HomeContentCoordinator {
  _Content(this.news, this.promo);
  final HomeContentSnapshot news, promo;
  bool failNews = false;
  bool stall = false;
  int reads = 0;
  final stalled = Completer<void>();
  final Set<String> denied = {};
  void deny(String section) {
    denied.add(section);
    notifyListeners();
  }

  void allow(String section) {
    denied.remove(section);
    notifyListeners();
  }

  @override
  bool isDenied(String section) => denied.contains(section);
  @override
  Future<HomeContentSnapshot?> read(
      String section, SessionCapabilities caps) async {
    reads++;
    if (stall) await stalled.future;
    if (section == 'news' && failNews) throw StateError('synthetic failure');
    return caps.capture(SessionCapability.cachedRead) == null
        ? null
        : (section == 'news' ? news : promo);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _DisposeAction extends StatefulWidget {
  const _DisposeAction(this.action);
  final VoidCallback action;
  @override
  State<_DisposeAction> createState() => _DisposeActionState();
}
class _DisposeActionState extends State<_DisposeAction> {
  @override
  void dispose() { widget.action(); super.dispose(); }
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('refresh keeps validated current news frame and drops it on denial', (tester) async {
    final bytes = Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII='));
    final item = HomeNewsItem(id: 'n', title: 'Refresh news', subtitle: '', body: '',
        icon: Icons.info, gradientColors: const [], type: HomeNewsType.update,
        createdAt: DateTime.utc(2026), imagePath: 'news/a.png', imageBytes: bytes);
    final dashboard = _RefreshDashboard(item);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(dashboardService: dashboard,
        promoService: _Promo(), notificationsApi: _Notifications())));
    await tester.pumpAndSettle();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).data.news.single.imageBytes, bytes);
    dashboard.returnCached = true;
    dashboard.loadGate = Completer<void>();
    final before = dashboard.imageValidationCalls;
    final refreshing = tester.widget<StudentHomeView>(find.byType(StudentHomeView)).onRefresh!();
    await tester.pump();
    await tester.pump();
    expect(dashboard.imageValidationCalls, greaterThan(before));
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).data.news.single.imageBytes, bytes);
    dashboard.loadGate!.complete();
    await refreshing;
    dashboard.loadGate = null;
    await tester.pumpAndSettle();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).data.news.single.imageBytes, bytes);
    dashboard.rejectImages = true;
    await tester.widget<StudentHomeView>(find.byType(StudentHomeView)).onRefresh!();
    await tester.pumpAndSettle();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).data.news.single.imageBytes, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('opening cached story revalidates bytes shown on the home card', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('story-check');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!), isTrue);
    final bytes = Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII='));
    final content = _Content(HomeContentSnapshot([{
      'id': 'n', 'title': 'Story news', 'body': 'Story text',
      'created_at': '2026-11-06T00:00:00Z', 'variant': 'imageOverlay',
      'image_path': 'news/a.png', '_offline_image': 'n',
    }], {'n': bytes}), const HomeContentSnapshot([], {}));
    final dashboard = _Dashboard();
    await tester.pumpWidget(MaterialApp(home: HomeScreen(dashboardService: dashboard,
        cachedReader: _Reader(caps), homeContent: content, homeContentCapabilities: caps)));
    await tester.pumpAndSettle();
    expect(find.text('Story news'), findsWidgets);
    final before = dashboard.imageValidationCalls;
    dashboard.rejectImages = true;
    await tester.tap(find.text('Story news').first);
    await tester.pumpAndSettle();
    expect(dashboard.imageValidationCalls, greaterThan(before));
    final sheet = tester.widget<StudentNewsStorySheet>(find.byType(StudentNewsStorySheet));
    expect(sheet.news.single.imageBytes, isNull);
    await tester.pumpWidget(const SizedBox());
    caps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('cold snapshot uses validated news bytes rather than preloaded bytes', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('snapshot-check');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!), isTrue);
    final bytes = Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII='));
    final content = _Content(HomeContentSnapshot([{
      'id': 'n', 'title': 'Snapshot news', 'body': 'Text',
      'created_at': '2026-11-06T00:00:00Z', 'variant': 'imageOverlay',
      'image_path': 'news/a.png', '_offline_image': 'n',
    }], {'n': bytes}), const HomeContentSnapshot([], {}));
    final dashboard = _Dashboard(rejectImages: true);
    await tester.pumpWidget(MaterialApp(home: HomeScreen(dashboardService: dashboard,
        cachedReader: _Reader(caps), homeContent: content, homeContentCapabilities: caps)));
    await tester.pumpAndSettle();
    expect(find.text('Snapshot news'), findsWidgets);
    expect(dashboard.imageValidationCalls, greaterThan(0));
    expect(find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage &&
        identical((w.image as MemoryImage).bytes, bytes)), findsNothing);
    await tester.pumpWidget(const SizedBox());
    caps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('content revoke during sibling disposal leaves home usable', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('dispose-content');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final readerCaps = SessionCapabilities(scope), contentCaps = SessionCapabilities(scope);
    for (final caps in [readerCaps, contentCaps]) {
      expect(caps.grant(SessionCapabilityMode.cacheOnly,
          caps.beginAuthorization(scope.capture()!)!), isTrue);
    }
    final reader = _Reader(readerCaps), dashboard = _Dashboard();
    final content = _Content(const HomeContentSnapshot([], {}), const HomeContentSnapshot([], {}));
    Widget app(bool sibling) => MaterialApp(home: Stack(children: [
      HomeScreen(key: const ValueKey('home'), dashboardService: dashboard,
          cachedReader: reader, homeContent: content, homeContentCapabilities: contentCaps),
      if (sibling) _DisposeAction(contentCaps.block),
    ]));
    await tester.pumpWidget(app(true));
    for (var i = 0; i < 8; i++) await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(app(false));
    for (var i = 0; i < 8; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(tester.takeException(), isNull);
    expect(reader.canRead, isTrue);
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    readerCaps.dispose(); contentCaps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('independent content revoke hides news and rejects stale reads', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('independent-content');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final readerCaps = SessionCapabilities(scope), contentCaps = SessionCapabilities(scope);
    void grant(SessionCapabilities c) => expect(c.grant(SessionCapabilityMode.cacheOnly,
        c.beginAuthorization(scope.capture()!)!), isTrue);
    grant(readerCaps); grant(contentCaps);
    HomeContentSnapshot news(String title) => HomeContentSnapshot([
      {'id': title, 'title': title, 'body': 'text', 'created_at': '2026-11-06T00:00:00Z'}
    ], const {});
    final first = _Content(news('Первая новость'), const HomeContentSnapshot([], {}));
    final late = _Content(news('Устаревшая новость'), const HomeContentSnapshot([], {}))..stall = true;
    final fresh = _Content(news('Свежая новость'), const HomeContentSnapshot([], {}));
    final reader = _Reader(readerCaps), dashboard = _Dashboard();
    Widget app(_Content c) => MaterialApp(home: HomeScreen(dashboardService: dashboard,
        cachedReader: reader, homeContent: c, homeContentCapabilities: contentCaps));
    await tester.pumpWidget(app(first));
    for (var i = 0; i < 10; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Первая новость'), findsWidgets);
    await tester.tap(find.text('Первая новость').first);
    await tester.pumpAndSettle();
    expect(find.text('text'), findsWidgets);
    contentCaps.block();
    for (var i = 0; i < 10; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(reader.canRead, isTrue);
    expect(find.text('Первая новость'), findsNothing);
    expect(find.text('text'), findsNothing);
    await tester.pumpWidget(app(late));
    grant(contentCaps);
    await tester.pump();
    contentCaps.block();
    await tester.pumpWidget(app(fresh));
    grant(contentCaps);
    for (var i = 0; i < 10; i++) await tester.pump(const Duration(milliseconds: 30));
    late.stalled.complete();
    for (var i = 0; i < 15; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Устаревшая новость'), findsNothing);
    expect(find.text('Свежая новость'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    readerCaps.dispose(); contentCaps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('replacing content coordinator fences its delayed old result', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('content-swap');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    HomeContentSnapshot news(String title) => HomeContentSnapshot([
      {'id': title, 'title': title, 'body': 'text', 'created_at': '2026-11-06T00:00:00Z'}
    ], const {});
    final oldContent = _Content(news('Старая новость'), const HomeContentSnapshot([], {}))..stall = true;
    final newContent = _Content(news('Новая новость'), const HomeContentSnapshot([], {}));
    final reader = _Reader(caps), dashboard = _Dashboard();
    Widget app(_Content content) => MaterialApp(home: HomeScreen(dashboardService: dashboard,
        cachedReader: reader, homeContent: content, homeContentCapabilities: caps));
    await tester.pumpWidget(app(oldContent)); await tester.pump();
    await tester.pumpWidget(app(newContent)); await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    for (var i = 0; i < 8; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Новая новость'), findsWidgets);
    oldContent.stalled.complete();
    for (var i = 0; i < 8; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(find.text('Старая новость'), findsNothing);
    expect(find.text('Новая новость'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
    caps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('late optional sections are consumed once without reload loop', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('late-content');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    final content = _Content(const HomeContentSnapshot([], {}), const HomeContentSnapshot([], {}))..stall = true;
    await tester.pumpWidget(MaterialApp(home: HomeScreen(dashboardService: _Dashboard(),
        cachedReader: _Reader(caps), homeContent: content, homeContentCapabilities: caps)));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 1100)); await tester.pump();
    expect(content.reads, 2);
    content.stalled.complete();
    for (var i = 0; i < 12; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(content.reads, 2);
    await tester.pumpWidget(const SizedBox());
    caps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('late local profile read refreshes offline home without network', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('late-home');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final prefs = await SharedPreferences.getInstance();
    HomeSnapshotCache cache(Future<SharedPreferences> Function() preferences) => HomeSnapshotCache(
      project: 'test-project', authScope: scope, currentUserId: () => session.user.id,
      sessionGeneration: () => scope.generation, sessionIdentity: () => session.accessToken,
      preferences: preferences);
    final writer = cache(() async => prefs);
    expect(await writer.write(scope: writer.captureScope('late-home')!, section: HomeSnapshotSection.profile,
        items: [{'id': 'late-home', 'name': 'Восстановленный профиль'}], savedAt: DateTime.now()), isTrue);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    final gate = Completer<SharedPreferences>();
    final monthGate = Completer<SharedPreferences>();
    final reader = CachedHomeScheduleReader(capabilities: caps, home: cache(() => gate.future),
        schedule: ScheduleMonthCache(scope, 'test-project', preferences: () => monthGate.future));
    await tester.pumpWidget(MaterialApp(home: HomeScreen(dashboardService: _Dashboard(), cachedReader: reader)));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 1100)); await tester.pump();
    expect(find.textContaining('Восстановленный профиль'), findsNothing);
    gate.complete(prefs);
    await tester.pump();
    // Profile returns after its deadline while the first dashboard load is
    // still waiting for the month. The retry must be queued, not dropped.
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 1100));
    for (var i = 0; i < 8; i++) await tester.pump(const Duration(milliseconds: 30));
    expect(find.textContaining('Восстановленный профиль'), findsWidgets);
    monthGate.complete(prefs);
    await tester.pumpWidget(const SizedBox());
    caps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('stalled optional content does not block offline home', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('qa-stalled');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    final content = _Content(const HomeContentSnapshot([], {}), const HomeContentSnapshot([], {}))..stall = true;
    await tester.pumpWidget(MaterialApp(home: HomeScreen(dashboardService: _Dashboard(),
        cachedReader: _Reader(caps), homeContent: content, homeContentCapabilities: caps)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(find.textContaining('QA'), findsWidgets);
    expect(find.text('Не удалось загрузить главную'), findsNothing);
    caps.block();
    content.stalled.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    caps.dispose(); scope.dispose(); await events.close();
  });
  testWidgets('optional content failure leaves the cached dashboard usable',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('qa');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    final content = _Content(
        const HomeContentSnapshot([], {}), const HomeContentSnapshot([], {}))
      ..failNews = true;
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: _Dashboard(),
            cachedReader: _Reader(caps),
            homeContent: content,
            homeContentCapabilities: caps)));
    await tester.pumpAndSettle();
    expect(find.textContaining('QA'), findsWidgets);
    expect(find.text('Не удалось загрузить главную'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
  testWidgets(
      'online story hides immediately on barrier close without further writes',
      (tester) async {
    final dashboard = _OnlineDashboard();
    final barrier = OnlineSideEffectBarrier(ownerIsCurrent: () => true);
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: dashboard,
            promoService: _Promo(),
            notificationsApi: _Notifications(),
            onlineBarrier: barrier)));
    await tester.pumpAndSettle();
    final initialBarriers = tester.widgetList(find.byType(ModalBarrier)).length;
    await tester.tap(find.text('Online news').first);
    await tester.pumpAndSettle();
    expect(find.text('Online text'), findsWidgets);
    final writes = dashboard.writes, reads = dashboard.reads;
    barrier.close();
    await tester.pump();
    await tester.pump();
    expect(find.text('Online text'), findsNothing);
    expect(
        tester.widgetList(find.byType(ModalBarrier)).length, initialBarriers);
    expect(dashboard.writes, writes);
    expect(dashboard.reads, reads);
    expect(barrier.activeCount, greaterThan(0));
    dashboard.markGate.complete();
    await tester.pump();
    expect(barrier.activeCount, 0);
    expect(
        await barrier.closeAndDrain(timeout: const Duration(seconds: 1)), true);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'offline home renders locally saved news and banner, then hides on revoke',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('qa');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    final bytes = Uint8List.fromList(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII='));
    final content = _Content(
        HomeContentSnapshot([
          {
            'id': 'n',
            'title': 'Локальная новость',
            'body': 'Сохранённый текст новости',
            'created_at': '2026-11-06T00:00:00Z',
            'variant': 'imageOverlay',
            '_offline_image': 'n'
          }
        ], {
          'n': bytes
        }),
        HomeContentSnapshot([
          {
            'id': 'p',
            'template_key': 'home_promo_v1',
            'schema_version': 1,
            'origin': 'admin',
            'placement': 'home_promo',
            '_offline_image': 'p',
            'payload': {
              'title': 'Локальный баннер',
              'subtitle': 'Описание',
              'icon_key': 'psychology',
              'gradient_colors': ['#FFFBFF', '#F3EEF9'],
              'cta_label': 'Открыть',
              'dismissible': false,
              'card_variant': 'image_full',
              'image_asset_id': 'asset'
            }
          }
        ], {
          'p': bytes
        }));
    final reader = _Reader(caps);
    await tester.pumpWidget(MaterialApp(
        home: ListenableBuilder(
            listenable: caps,
            builder: (_, __) => reader.canRead
                ? HomeScreen(
                    dashboardService: _Dashboard(),
                    cachedReader: reader,
                    homeContent: content,
                    homeContentCapabilities: caps)
                : const Text('closed'))));
    await tester.pumpAndSettle();
    final initialBarriers = tester.widgetList(find.byType(ModalBarrier)).length;
    expect(find.text('Локальная новость'), findsWidgets);
    expect(find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsWidgets);
    await tester.tap(find.text('Локальная новость').first);
    await tester.pumpAndSettle();
    expect(find.text('Сохранённый текст новости'), findsWidgets);
    Navigator.of(tester.element(find.text('Сохранённый текст новости').first))
        .pop();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Локальный баннер'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Локальный баннер'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Локальная новость'), -300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Локальная новость').first);
    await tester.pumpAndSettle();
    expect(find.text('Сохранённый текст новости'), findsWidgets);
    content.deny('news');
    await tester.pump();
    await tester.pump();
    expect(find.text('Сохранённый текст новости'), findsNothing);
    expect(find.text('Локальная новость'), findsNothing);
    expect(
        tester.widgetList(find.byType(ModalBarrier)).length, initialBarriers);
    content.allow('news');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Локальная новость').first);
    await tester.pumpAndSettle();
    expect(find.text('Сохранённый текст новости'), findsWidgets);
    caps.block();
    await tester.pump();
    await tester.pump();
    expect(find.text('Локальная новость'), findsNothing);
    expect(find.text('Сохранённый текст новости'), findsNothing);
    expect(find.text('closed'), findsOneWidget);
    expect(
        tester.widgetList(find.byType(ModalBarrier)).length, initialBarriers);
    await tester.pumpWidget(const SizedBox());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
}
