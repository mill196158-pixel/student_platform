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
  final events = <String>[];
  @override
  Future<void> recordEvent(String id, String event) async =>
      events.add('$id:$event');
  final pending = Completer<HomePromoLoadResult>();
  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) => pending.future;
  @override
  Future<HomePromoLoadResult> loadCached() async => HomePromoLoadResult(cards: [
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
            'image_asset_id': 'image-a',
            'icon_asset_id': 'icon-a',
            'home_slot': 'after_news'
          },
        })!,
      ]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Media implements ContentMediaService {
  final requested = <String>[];
  @override
  Future<Uint8List?> fetchBytes(String id, {String? contentVersion}) async {
    requested.add(id);
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SlowMedia extends Media {
  final image = Completer<Uint8List?>();
  final icon = Completer<Uint8List?>();
  @override
  Future<Uint8List?> fetchBytes(String id, {String? contentVersion}) {
    requested.add(id);
    return id == 'image-a' ? image.future : icon.future;
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

void main() {
  testWidgets('ready promo is not counted behind loading or an inactive tab',
      (t) async {
    final active = ValueNotifier<bool>(false);
    final dashboard = ProgressiveDashboard();
    final promo = Promo();
    final media = SlowMedia();
    final notifications = Notifications();
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            activeListenable: active,
            dashboardService: dashboard,
            promoService: promo,
            contentMedia: media,
            notificationsApi: notifications)));
    await t.pump();
    media.image.complete(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='));
    media.icon.complete(null);
    await t.pump();
    await t.pump();
    expect(promo.events, isEmpty);
    dashboard.updates.single(partial('a', 'Alice'));
    await t.pump();
    expect(promo.events, isEmpty);
    active.value = true;
    await t.pump();
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
    testWidgets('promo stays hidden until usable image; success=$success',
        (t) async {
      final dashboard = ProgressiveDashboard();
      final promo = Promo();
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
      await t.pump();
      expect(media.requested, containsAll(['image-a', 'icon-a']));
      var view = t.widget<StudentHomeView>(find.byType(StudentHomeView));
      expect(view.hideHomePromo, isTrue);
      expect(view.homePromoPlacements, isEmpty);
      expect(promo.events, isEmpty);
      expect(find.text('Cached promo'), findsNothing);
      if (success) {
        media.image.complete(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='));
      } else {
        media.image.completeError(StateError('offline'));
      }
      await t.pump();
      await t.pump();
      view = t.widget<StudentHomeView>(find.byType(StudentHomeView));
      expect(view.hideHomePromo, !success);
      expect(view.homePromoPlacements.length, success ? 1 : 0);
      expect(promo.events, success ? ['cached:impression'] : isEmpty);
      expect(media.icon.isCompleted, isFalse,
          reason: 'main image does not wait for icon');
      media.icon.complete(null);
      dashboard.requests.single.complete(partial('a', 'Alice'));
      promo.pending.complete(await promo.loadCached());
      notifications.pending.complete(0);
      await t.pumpAndSettle();
      expect(promo.events.length, success ? 1 : 0);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets(
      'deadline releases coalescing and late attempt cannot overwrite retry',
      (t) async {
    final dashboard = ProgressiveDashboard();
    final promo = Promo();
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
    final promo = Promo();
    final notifications = Notifications();
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: dashboard,
            promoService: promo,
            notificationsApi: notifications,
            contentMedia: Media())));
    await t.pump();
    dashboard.updates[0](partial('a', 'Alice'));
    await t.pump();
    expect(find.byType(StudentHomeView), findsOneWidget);
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
    await t.pump();
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
    final media = Media();
    await t.pumpWidget(MaterialApp(
        home: HomeScreen(
            dashboardService: dashboard,
            notificationsApi: notifications,
            promoService: promo,
            contentMedia: media)));
    await t.pump();
    await t.pump();
    expect(media.requested, contains('image-a'));
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
