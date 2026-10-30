import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/password_policy.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';

void main() {
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
        expect(find.text('Login'), findsOneWidget);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('user'), isFalse);
        expect(prefs.containsKey('loggedIn'), isFalse);
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
