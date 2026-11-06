import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/password_policy.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';

void main() {
  testWidgets('stale startup retries and continues with the current session', (tester) async {
    var calls = 0;
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(path: '/splash', builder: (_, __) => SplashScreen(
          restoreStatus: () async => ++calls == 1
              ? SessionRestoreStatus.stale : SessionRestoreStatus.restored)),
      GoRoute(path: '/home', builder: (_, __) => const Scaffold(body: Text('Home'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('repeated stale startup shows retry instead of an endless loader', (tester) async {
    var calls = 0;
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(path: '/splash', builder: (_, __) => SplashScreen(
          restoreStatus: () async { calls++; return SessionRestoreStatus.stale; })),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Повторить'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(calls, 4);
    expect(find.text('Повторить'), findsOneWidget);
  });
  testWidgets('temporary restore failure keeps local profile and does not enter home',
      (tester) async {
    SharedPreferences.setMockInitialValues({'loggedIn': true, 'user': 'cached'});
    var homeBuilds = 0;
    var restores = 0;
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(path: '/splash', builder: (_, __) => SplashScreen(
          restoreStatus: () async => ++restores == 1
              ? SessionRestoreStatus.transportFailure
              : SessionRestoreStatus.restored)),
      GoRoute(path: '/login', builder: (_, __) => const Scaffold(body: Text('Login'))),
      GoRoute(path: '/home', builder: (_, __) {
        homeBuilds++;
        return const Scaffold(body: Text('Protected home'));
      }),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('user'), 'cached');
    expect(prefs.getBool('loggedIn'), isTrue);
    expect(homeBuilds, 0);
    expect(find.text('Login'), findsNothing);
    expect(find.text('Нет соединения.'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(restores, 2);
    expect(find.text('Protected home'), findsOneWidget);
  });
  testWidgets('manual retry is single-flight and ignores results after leaving',
      (tester) async {
    final first = Completer<SessionRestoreStatus>();
    var calls = 0;
    final router = GoRouter(initialLocation: '/splash', routes: [
      GoRoute(path: '/splash', builder: (_, __) => SplashScreen(
          manualRetry: true,
          initialNetworkUnavailable: true,
          restoreStatus: () { calls++; return first.future; })),
      GoRoute(path: '/home', builder: (_, __) => const Scaffold(body: Text('Home'))),
      GoRoute(path: '/guest', builder: (_, __) => const Scaffold(body: Text('Guest'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Повторить'));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    router.go('/guest');
    await tester.pumpAndSettle();
    first.complete(SessionRestoreStatus.restored);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Guest'), findsOneWidget);
    expect(find.text('Home'), findsNothing);
  });
  for (final outcome in ['allow', 'change', 'error', 'no_session']) {
    testWidgets('startup $outcome keeps one authoritative router gate',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {'loggedIn': true, 'user': 'legacy'});
      final policy = Completer<bool>();
      var calls = 0;
      var homeBuilds = 0;
      final hasSession = outcome != 'no_session';
      final router = GoRouter(
          initialLocation: '/splash',
          redirect: (_, state) => authRouteRedirect(
              path: state.uri.path,
              hasSession: hasSession,
              passwordChangeRequired: () {
                calls++;
                return policy.future;
              }),
          routes: [
            GoRoute(
                path: '/splash',
                builder: (_, __) =>
                    SplashScreen(restoreSession: () async => hasSession)),
            GoRoute(
                path: '/home',
                builder: (_, __) {
                  homeBuilds++;
                  return const Scaffold(body: Text('Protected home'));
                }),
            GoRoute(
                path: '/guest',
                builder: (_, __) => const Scaffold(body: Text('Guest'))),
            GoRoute(
                path: '/login',
                builder: (_, __) => const Scaffold(body: Text('Login'))),
            GoRoute(
                path: '/change-password',
                builder: (_, __) =>
                    const Scaffold(body: Text('Change password'))),
          ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(homeBuilds, 0);
      if (!hasSession) {
        expect(calls, 0);
        expect(find.text('Guest'), findsOneWidget);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('user'), 'legacy');
        expect(prefs.getBool('loggedIn'), isTrue);
      } else {
        expect(calls,
            1); // Waiting on server: protected screen must still not exist.
        if (outcome == 'error') {
          policy.completeError(StateError('offline'));
        } else {
          policy.complete(outcome == 'change');
        }
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(homeBuilds, outcome == 'allow' ? 1 : 0);
        expect(
            find.text(outcome == 'allow'
                ? 'Protected home'
                : outcome == 'change'
                    ? 'Change password'
                    : 'Login'),
            findsOneWidget);
      }
    });
  }
}
