import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';

import 'home_promo_loading_test.dart' show Dashboard, Promo, Media, Notifications;

class _Reader implements CachedHomeScheduleReader {
  @override
  bool get canRead => true;
  @override
  Future<HomeDashboardData> readDashboard({DateTime? date}) async =>
      HomeDashboardData(
        profile: const HomeUserProfile(name: 'Offline'),
        scheduleDate: DateTime.now(),
        todayLessons: const [],
        assignments: const [],
        news: const [],
      );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('offline status is below Android top system inset', (tester) async {
    const topInset = 32.0;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(800, 600),
          padding: EdgeInsets.only(top: topInset),
          viewPadding: EdgeInsets.only(top: topInset),
        ),
        child: HomeScreen(
          cachedReader: _Reader(),
          dashboardService: Dashboard(),
          promoService: Promo(),
          contentMedia: Media(),
          notificationsApi: Notifications(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    final status = find.textContaining('Без сети');
    expect(status, findsOneWidget);
    expect(tester.getTopLeft(status).dy, greaterThanOrEqualTo(topInset));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
