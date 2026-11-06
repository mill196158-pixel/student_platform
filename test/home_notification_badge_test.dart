import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/services/push/in_app_notification_bus.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_promo_loading_test.dart' show ProgressiveDashboard, Promo, Media, partial;
import 'auth_session_scope_test.dart' show fakeSession;

class _Notifications implements AppNotificationsApi {
  final requests = <Completer<int>>[];
  @override
  Future<int> unreadCount() {
    final request = Completer<int>();
    requests.add(request);
    return request.future;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('badge preserves confirmed count on error and rejects stale owner', (tester) async {
    final dashboard = ProgressiveDashboard();
    final notifications = _Notifications();
    final promo = Promo();
    await tester.pumpWidget(MaterialApp(home: HomeScreen(
      dashboardService: dashboard, promoService: promo,
      contentMedia: Media(), notificationsApi: notifications)));
    await tester.pump();
    dashboard.updates.single(partial('a', 'Alice'));
    await tester.pump();
    notifications.requests.single.complete(5);
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 5);

    InAppNotificationBus.instance.requestBadgeRefresh();
    await tester.pump();
    notifications.requests.last.completeError(StateError('network'));
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 5);

    InAppNotificationBus.instance.requestBadgeRefresh();
    await tester.pump();
    notifications.requests.last.complete(0);
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 0);

    InAppNotificationBus.instance.requestBadgeRefresh();
    await tester.pump();
    final stale = notifications.requests.last;
    dashboard.user = 'b';
    InAppNotificationBus.instance.requestBadgeRefresh();
    await tester.pump();
    notifications.requests.last.complete(2);
    await tester.pump();
    stale.complete(9);
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 2);
    dashboard.requests.single.complete(partial('b', 'Bob'));
    promo.pending.complete(await promo.loadCached());
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('initial session readiness starts a badge query', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    Session sessionFor(String sid, int version) {
      String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token = '${part({'alg': 'none'})}.${part({
        'iss': '${SupabaseConfig.url}/auth/v1', 'sub': 'a', 'session_id': sid,
        'aud': 'authenticated', 'role': 'authenticated', 'iat': 100, 'exp': 200,
        'version': version,
      })}.signature';
      return fakeSession('a', access: token, refresh: 'refresh-$version');
    }
    var session = sessionFor('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 1);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    final dashboard = ProgressiveDashboard();
    final notifications = _Notifications();
    final promo = Promo();
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope, child: HomeScreen(
        dashboardService: dashboard, promoService: promo,
        contentMedia: Media(), notificationsApi: notifications))));
    await tester.pump();
    expect(notifications.requests, isEmpty);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    await tester.pump();
    expect(notifications.requests, isNotEmpty);
    for (final request in notifications.requests) { request.complete(3); }
    dashboard.updates.last(partial('a', 'Alice'));
    for (final request in dashboard.requests) { request.complete(partial('a', 'Alice')); }
    promo.pending.complete(await promo.loadCached());
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 3);
    session = sessionFor('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 2);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 3);
    final refreshRequest = notifications.requests.last;
    if (!refreshRequest.isCompleted) refreshRequest.completeError(StateError('offline'));
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 3);
    session = sessionFor('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 3);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await tester.pump();
    expect(tester.widget<StudentHomeView>(find.byType(StudentHomeView)).notificationCount, 0);
    for (final request in notifications.requests) {
      if (!request.isCompleted) request.complete(0);
    }
    for (final request in dashboard.requests) {
      if (!request.isCompleted) request.complete(partial('a', 'Alice'));
    }
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await events.close();
  });
}
