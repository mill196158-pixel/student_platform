import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/qa_no_automatic_writes.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'home_promo_loading_test.dart' show ProgressiveDashboard, Promo, SlowMedia, Notifications, partial;

void main() {
  testWidgets('visible home promo skips automatic impression only in QA', (tester) async {
    final dashboard = ProgressiveDashboard();
    final promo = Promo();
    final media = SlowMedia();
    final notifications = Notifications();
    await tester.pumpWidget(MaterialApp(home: HomeScreen(dashboardService: dashboard,
      promoService: promo, contentMedia: media, notificationsApi: notifications)));
    await tester.pump();
    dashboard.updates.single(partial('a', 'Alice'));
    await tester.pump();
    media.image.complete(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg=='));
    media.icon.complete(null);
    await tester.pump();
    await tester.pump();
    expect(find.text('Cached promo'), findsOneWidget);
    expect(promo.events, qaNoAutomaticWrites ? isEmpty : ['cached:impression']);
    dashboard.requests.single.complete(partial('a', 'Alice'));
    promo.pending.complete(await promo.loadCached());
    notifications.pending.complete(0);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
