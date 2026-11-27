import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';

final _savedPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGPQ3dKDFTEMLQkAkBVbQXClKcwAAAAASUVORK5CYII=');
final _replacementPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGMwCdiHFTEMLQkAUhlQgeFyboYAAAAASUVORK5CYII=');

class Dashboard implements HomeDashboardService {
  @override
  String? get currentUserId => 'fixture';
  final pending = Completer<HomeDashboardData>();
  @override
  Future<HomeDashboardData> load(
          {void Function(HomeDashboardData)? onUpdate,
          HomeDashboardData? previous}) =>
      pending.future;
  @override
  Future<List<HomeNewsItem>> loadCachedNews() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Notifications implements AppNotificationsApi {
  final pending = Completer<int>();
  @override
  Future<int> unreadCount() => pending.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Promo implements HomePromoService {
  Promo({this.hasCache = true});

  final bool hasCache;
  final events = <String>[];
  int loadCalls = 0;
  @override
  Future<void> recordEvent(String id, String event) async =>
      events.add('$id:$event');
  final pending = Completer<HomePromoLoadResult>();
  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) {
    loadCalls++;
    return pending.future;
  }

  @override
  Future<HomePromoLoadResult> loadCached() async => hasCache
      ? withCover('image-a')
      : const HomePromoLoadResult(intentionallyEmpty: true);

  HomePromoLoadResult withCover(String cover, {String icon = 'icon-a'}) =>
      HomePromoLoadResult(cards: [
        ManagedContentCard.tryParseHomePromo({
          'id': 'cached',
          'template_key': 'home_promo_v1',
          'schema_version': 2,
          'placement': 'home_promo',
          'sort_order': 0,
          'priority': 0,
          'origin': 'admin',
          'payload': {
            'title': 'Cached promo',
            'subtitle': 'Subtitle',
            'icon_key': 'psychology',
            'gradient_colors': ['#FFFBFF', '#F3EEF9'],
            'cta_label': 'Open',
            'cta_route': '/my-diary',
            'dismissible': true,
            'card_variant': 'image_full',
            'image_asset_id': cover,
            'icon_asset_id': icon,
            'home_slot': 'after_news'
          },
        })!,
      ]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Media implements ContentMediaService {
  Media({this.disk = const {}, this.live = const {}});

  final Map<String, Uint8List> disk;
  final Map<String, Uint8List> live;
  final diskRequests = <String>[];
  final networkRequests = <String>[];

  @override
  Future<Uint8List?> readCachedBytes(String id,
      {String? contentVersion}) async {
    diskRequests.add(id);
    return disk[id];
  }

  @override
  Future<Uint8List?> fetchBytes(String id, {String? contentVersion}) async {
    networkRequests.add(id);
    return live[id];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SlowMedia extends Media {
  SlowMedia({super.disk});

  final image = Completer<Uint8List?>();
  final icon = Completer<Uint8List?>();
  @override
  Future<Uint8List?> fetchBytes(String id, {String? contentVersion}) {
    networkRequests.add(id);
    return id.startsWith('image-') ? image.future : icon.future;
  }
}

class ProgressiveDashboard implements HomeDashboardService {
  String user = 'a';
  @override
  String? get currentUserId => user;
  final updates = <void Function(HomeDashboardData)>[];
  final requests = <Completer<HomeDashboardData>>[];
  @override
  Future<HomeDashboardData> load(
      {void Function(HomeDashboardData)? onUpdate,
      HomeDashboardData? previous}) {
    updates.add(onUpdate!);
    final request = Completer<HomeDashboardData>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<List<HomeNewsItem>> loadCachedNews() async => [];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

HomeDashboardData partial(String id, String name) => HomeDashboardData(
    profile: HomeUserProfile(id: id, name: name),
    scheduleDate: DateTime.now(),
    todayLessons: const [],
    assignments: const [],
    news: const [],
    scheduleStatus: 'Загружаем расписание…',
    assignmentsStatus: 'Загружаем ближайшие дела…');

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; !ready() && frame < 100; frame++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(ready(), isTrue);
}

StudentHomeView _home(WidgetTester tester) =>
    tester.widget<StudentHomeView>(find.byType(StudentHomeView));

void main() {
  testWidgets('replacement promo preserves the whole saved slot until decoded',
      (t) async {
    final dashboard = ProgressiveDashboard();
    final notifications = Notifications()..pending.complete(0);
    final promo = Promo();
    final media = SlowMedia(disk: {'image-a': _savedPng, 'icon-a': _savedPng});
    await t.pumpWidget(MaterialApp(
      home: HomeScreen(
        dashboardService: dashboard,
        promoService: promo,
        contentMedia: media,
        notificationsApi: notifications,
      ),
    ));
    await t.pump();
    dashboard.requests.single.complete(partial('a', 'Alice'));
    final summary = find.text('Сводка дня');
    final card = find.text('Cached promo');
    await _waitFor(t, () => card.evaluate().isNotEmpty);
    final summaryPosition = t.getTopLeft(summary);
    final originalCardPosition = t.getTopLeft(card);
    expect(originalCardPosition.dy, lessThan(summaryPosition.dy));

    promo.pending.complete(promo.withCover('image-b', icon: 'icon-b'));
    await _waitFor(t, () => media.networkRequests.length == 2);
    expect(media.networkRequests, containsAll(['image-b', 'icon-b']));
    media.image.complete(_replacementPng);
    await t.pump();
    final placement = _home(t).homePromoPlacements.single;
    expect(placement.imageLoading, isFalse);
    expect(placement.imageBytes, same(_savedPng));
    expect(placement.iconBytes, same(_savedPng));
    expect(t.getTopLeft(summary), summaryPosition);
    expect(t.getTopLeft(card), originalCardPosition);

    media.icon.complete(_replacementPng);
    await _waitFor(
        t,
        () => identical(
            _home(t).homePromoPlacements.single.imageBytes, _replacementPng));
    expect(t.getTopLeft(summary), summaryPosition);
    expect(t.getTopLeft(card), originalCardPosition);
    expect(_home(t).homePromoPlacements.single.imageState?.isReady, isTrue);
    expect(
        _home(t).homePromoPlacements.single.iconBytes, same(_replacementPng));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('ready promo is not counted behind loading or an inactive tab',
      (t) async {
    final active = ValueNotifier<bool>(false);
    final dashboard = ProgressiveDashboard();
    final promo = Promo();
    final bytes = {'image-a': _savedPng, 'icon-a': _savedPng};
    final media = Media(disk: bytes, live: bytes);
    final notifications = Notifications();
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            activeListenable: active,
            dashboardService: dashboard,
            promoService: promo,
            contentMedia: media,
            notificationsApi: notifications)));
    await t.pump();
    expect(promo.events, isEmpty);
    dashboard.updates.single(partial('a', 'Alice'));
    await _waitFor(t, () => find.text('Cached promo').evaluate().isNotEmpty);
    expect(promo.events, isEmpty);
    active.value = true;
    await _waitFor(t, () => promo.events.isNotEmpty);
    expect(promo.events, ['cached:impression']);
    dashboard.requests.single.complete(partial('a', 'Alice'));
    promo.pending.complete(await promo.loadCached());
    notifications.pending.complete(0);
    await t.pumpAndSettle();
    expect(promo.events.length, 1);
    await t.pumpWidget(const SizedBox.shrink());
    active.dispose();
  });
  for (final success in [true, false]) {
    testWidgets('new promo waits for all of its usable media; success=$success',
        (t) async {
      final dashboard = ProgressiveDashboard();
      final promo = Promo(hasCache: false);
      final media = SlowMedia();
      final notifications = Notifications();
      await t.pumpWidget(MaterialApp(
          home: HomeScreen(
              dashboardService: dashboard,
              promoService: promo,
              contentMedia: media,
              notificationsApi: notifications)));
      await t.pump();
      dashboard.updates.single(partial('a', 'Alice'));
      await _waitFor(t, () => promo.loadCalls > 0);
      expect(media.diskRequests, isEmpty);
      expect(media.networkRequests, isEmpty);
      promo.pending.complete(promo.withCover('image-a'));
      await _waitFor(t, () => media.networkRequests.length == 2);
      expect(media.networkRequests, containsAll(['image-a', 'icon-a']));
      final view = _home(t);
      expect(view.hideHomePromo, isTrue);
      expect(view.homePromoPlacements, isEmpty);
      expect(promo.events, isEmpty);
      expect(find.text('Cached promo'), findsNothing);
      if (success) {
        media.image.complete(_savedPng);
      } else {
        media.image.completeError(StateError('offline'));
      }
      await t.pump();
      expect(_home(t).homePromoPlacements, isEmpty);
      expect(promo.events, isEmpty);
      media.icon.complete(_savedPng);
      dashboard.requests.single.complete(partial('a', 'Alice'));
      notifications.pending.complete(0);
      if (success) {
        await _waitFor(t, () => _home(t).homePromoPlacements.isNotEmpty);
      }
      await t.pumpAndSettle();
      expect(_home(t).hideHomePromo, !success);
      expect(_home(t).homePromoPlacements.length, success ? 1 : 0);
      expect(promo.events.length, success ? 1 : 0);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
      'deadline releases coalescing and late attempt cannot overwrite retry',
      (t) async {
    final dashboard = ProgressiveDashboard();
    final promo = Promo(hasCache: false);
    final notifications = Notifications();
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: dashboard,
            promoService: promo,
            notificationsApi: notifications,
            contentMedia: Media())));
    await t.pump();
    dashboard.updates[0](partial('a', 'Initial'));
    await t.pump();
    await t.pump(const Duration(seconds: 19));
    await t.pump();
    expect(find.text('Не всё удалось обновить. Повторить'), findsOneWidget);
    await t.tap(find.text('Не всё удалось обновить. Повторить'));
    await t.pump();
    expect(dashboard.requests, hasLength(2));
    dashboard.updates[1](partial('a', 'Retry'));
    dashboard.updates[0](partial('a', 'Obsolete'));
    await t.pump();
    expect(find.textContaining('Obsolete'), findsNothing);
    dashboard.requests[1].complete(partial('a', 'Retry'));
    dashboard.requests[0].complete(partial('a', 'Obsolete'));
    promo.pending.complete(const HomePromoLoadResult(intentionallyEmpty: true));
    notifications.pending.complete(0);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'partial dashboard visible before completion; coalesce and reject old account updates',
      (t) async {
    final dashboard = ProgressiveDashboard();
    final promo = Promo(hasCache: false);
    final notifications = Notifications();
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: dashboard,
            promoService: promo,
            notificationsApi: notifications,
            contentMedia: Media())));
    await t.pump();
    dashboard.updates[0](partial('a', 'Alice'));
    await _waitFor(t, () => find.textContaining('Alice').evaluate().isNotEmpty);
    expect(find.text('Сегодня выходной'), findsNothing);
    expect(find.text('Пока нет ближайших заданий'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(dashboard.requests, hasLength(1));
    dashboard.user = 'b';
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(dashboard.requests, hasLength(2));
    dashboard.updates[1](partial('b', 'Bob'));
    await _waitFor(t, () => find.textContaining('Bob').evaluate().isNotEmpty);
    dashboard.updates[0](partial('a', 'Wrong old account'));
    await t.pump();
    expect(find.textContaining('Wrong old account'), findsNothing);
    dashboard.requests[0].complete(partial('a', 'Wrong old account'));
    dashboard.requests[1].complete(partial('b', 'Bob'));
    promo.pending.complete(const HomePromoLoadResult(intentionallyEmpty: true));
    notifications.pending.complete(0);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'cached promo hydration does not wait for dashboard, badge or promo RPC',
      (t) async {
    final dashboard = Dashboard();
    final notifications = Notifications();
    final promo = Promo();
    final media = Media(disk: {'image-a': _savedPng, 'icon-a': _savedPng});
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: dashboard,
            notificationsApi: notifications,
            promoService: promo,
            contentMedia: media)));
    await t.pump();
    await t.pump();
    expect(media.diskRequests, containsAll(['image-a', 'icon-a']));
    expect(media.networkRequests, isEmpty);
    expect(promo.loadCalls, 0);
    expect(dashboard.pending.isCompleted, isFalse);
    expect(notifications.pending.isCompleted, isFalse);
    expect(promo.pending.isCompleted, isFalse);
    dashboard.pending.completeError(StateError('offline dashboard'));
    notifications.pending.complete(0);
    promo.pending.complete(const HomePromoLoadResult(intentionallyEmpty: true));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
