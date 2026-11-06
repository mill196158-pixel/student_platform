import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'home_promo_loading_test.dart'
    show Dashboard, Promo, Media, Notifications, ProgressiveDashboard, partial;

class _Dashboard extends Dashboard {
  int calls = 0;
  @override
  Future<HomeDashboardData> load(
      {void Function(HomeDashboardData)? onUpdate,
      HomeDashboardData? previous}) {
    calls++;
    return super.load(onUpdate: onUpdate, previous: previous);
  }

  @override
  Future<List<HomeNewsItem>> loadCachedNews() async {
    calls++;
    return [];
  }
}

class _Promo extends Promo {
  int calls = 0;
  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) {
    calls++;
    return super.load(writeCache: writeCache);
  }

  @override
  Future<HomePromoLoadResult> loadCached() {
    calls++;
    return super.loadCached();
  }
}

class _DelayedPromo extends Promo {
  final cached = Completer<HomePromoLoadResult>();
  int networkCalls = 0;
  @override
  Future<HomePromoLoadResult> loadCached() => cached.future;
  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) {
    networkCalls++;
    return super.load(writeCache: writeCache);
  }
}

class _Notifications extends Notifications {
  int calls = 0;
  @override
  Future<int> unreadCount() {
    calls++;
    return super.unreadCount();
  }
}

class _Reader implements CachedHomeScheduleReader {
  @override
  bool get canRead => true;
  @override
  Future<HomeDashboardData> readDashboard({DateTime? date}) async =>
      HomeDashboardData(
          profile: const HomeUserProfile(id: 'fixture', name: 'Офлайн имя'),
          scheduleDate: DateTime.now(),
          todayLessons: const [],
          assignments: const [],
          news: const [],
          scheduleStatus: 'Сохранённое расписание',
          assignmentsStatus: 'Сохранённые задания');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'existing home paints cache without dashboard, promo or notification requests',
      (tester) async {
    final dashboard = _Dashboard(),
        promo = _Promo(),
        media = Media(),
        notifications = _Notifications();
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            cachedReader: _Reader(),
            dashboardService: dashboard,
            promoService: promo,
            contentMedia: media,
            notificationsApi: notifications)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StudentHomeView), findsOneWidget);
    expect(find.textContaining('Офлайн имя'), findsOneWidget);
    expect(find.textContaining('новости и объявления могут быть недоступны'),
        findsOneWidget);
    expect(dashboard.calls, 0);
    expect(promo.calls, 0);
    expect(notifications.calls, 0);
    expect(promo.events, isEmpty);
    expect(media.requested, isEmpty);
    final view = tester.widget<StudentHomeView>(find.byType(StudentHomeView));
    expect(view.onAssignmentDoneTap, isNull);
    expect(view.onNotificationsTap, isNull);
    expect(view.onGroupActionTap, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('mode switch fences delayed online updates and resumes on return',
      (tester) async {
    final dashboard = ProgressiveDashboard(),
        promo = _Promo(),
        media = Media(),
        notifications = _Notifications();
    final offline = _Reader();
    Widget app(CachedHomeScheduleReader? reader) => MaterialApp(
        home: HomeScreen(
            key: const ValueKey('home'),
            cachedReader: reader,
            dashboardService: dashboard,
            promoService: promo,
            contentMedia: media,
            notificationsApi: notifications));
    await tester.pumpWidget(app(null));
    await tester.pump();
    expect(dashboard.requests.length, 1);
    dashboard.updates.first(partial('a', 'Первый онлайн'));
    await tester.pump();
    final oldHelp =
        tester.widget<StudentHomeView>(find.byType(StudentHomeView)).onHelpTap;
    await tester.pumpWidget(app(offline));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Офлайн имя'), findsOneWidget);
    oldHelp?.call();
    dashboard.updates.first(partial('a', 'Старый онлайн'));
    dashboard.requests.first.complete(partial('a', 'Старый онлайн'));
    notifications.pending.complete(99);
    promo.pending.complete(const HomePromoLoadResult(intentionallyEmpty: true));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Офлайн имя'), findsOneWidget);
    expect(find.textContaining('Старый онлайн'), findsNothing);
    expect(promo.events, isEmpty);
    await tester.pumpWidget(app(null));
    await tester.pump();
    expect(dashboard.requests.length, 2);
    dashboard.updates.last(partial('a', 'Снова онлайн'));
    dashboard.requests.last.complete(partial('a', 'Снова онлайн'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Снова онлайн'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('pending cached promo never starts network after offline switch',
      (tester) async {
    final dashboard = ProgressiveDashboard(),
        promo = _DelayedPromo(),
        media = Media(),
        notifications = _Notifications();
    Widget app(CachedHomeScheduleReader? reader) => MaterialApp(
        home: HomeScreen(
            key: const ValueKey('home-promo'),
            cachedReader: reader,
            dashboardService: dashboard,
            promoService: promo,
            contentMedia: media,
            notificationsApi: notifications));
    await tester.pumpWidget(app(null));
    await tester.pump();
    await tester.pumpWidget(app(_Reader()));
    await tester.pump();
    promo.cached.complete(const HomePromoLoadResult(intentionallyEmpty: true));
    dashboard.requests.first.complete(partial('a', 'stale'));
    notifications.pending.complete(0);
    await tester.pump();
    await tester.pump();
    expect(promo.networkCalls, 0);
    expect(find.textContaining('Офлайн имя'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
