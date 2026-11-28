import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_ui/student_ui.dart';

class _Dashboard implements HomeDashboardService {
  _Dashboard(this.news);

  final HomeNewsItem news;
  final reread = Completer<List<HomeNewsItem>>();

  @override
  String get currentUserId => 'test-student';

  @override
  Future<HomeDashboardData> load({
    void Function(HomeDashboardData)? onUpdate,
    HomeDashboardData? previous,
  }) async =>
      HomeDashboardData(
        profile: HomeUserProfile(id: currentUserId),
        scheduleDate: DateTime.now(),
        todayLessons: const [],
        assignments: const [],
        news: [news],
      );

  @override
  Future<List<HomeNewsItem>> validateNewsImages(List<HomeNewsItem> items) =>
      reread.future;

  @override
  Future<void> markNewsSeen(String id, {bool closed = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Promos implements HomePromoService {
  @override
  Future<HomePromoLoadResult> loadCached() async =>
      const HomePromoLoadResult(intentionallyEmpty: true);

  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) => loadCached();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifications implements AppNotificationsApi {
  @override
  Future<int> unreadCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
      'one tap opens the already decoded welcome cover during a stalled reread',
      (tester) async {
    final dashboard = _Dashboard(HomeNewsItem(
      id: '9658bbcf-7fc8-48cc-ae1f-21b1a0ad1523',
      title: 'Добро пожаловать',
      subtitle: 'Новости',
      body: 'Содержание новости',
      icon: Icons.article,
      gradientColors: const [Colors.blue, Colors.purple],
      type: HomeNewsType.update,
      createdAt: DateTime.utc(2026, 7, 22),
      variant: StudentHomeNewsVariant.imageOverlay,
      imagePath: 'news/fixture/welcome.png',
      imageBytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGPQ3dKDFTEMLQkAkBVbQXClKcwAAAAASUVORK5CYII='),
    ));
    addTearDown(() => dashboard.reread.complete([]));
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
        dashboardService: dashboard,
        promoService: _Promos(),
        notificationsApi: _Notifications(),
      ),
    ));
    final card = find.byType(StudentHomeNewsCard).hitTestable();
    for (var i = 0; card.evaluate().isEmpty && i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(card, findsOneWidget);
    final cover = tester.widget<StudentHomeNewsCard>(card).item.imageProvider;
    expect(cover, isNotNull);

    await tester.tap(card);
    await tester.pump();
    final story = find.byType(StudentNewsStorySheet);
    expect(story, findsOneWidget);
    expect(
        tester.widget<StudentNewsStorySheet>(story).news.single.imageProvider,
        same(cover));
    expect(dashboard.reread.isCompleted, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
