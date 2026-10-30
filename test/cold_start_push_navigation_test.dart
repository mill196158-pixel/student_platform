import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/password_policy.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';
import 'cold_start_session_test.dart' show sessionFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.com',
      publishableKey: 'test-public-key',
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false, detectSessionInUri: false),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());
  testWidgets(
      'cold push survives startup and still waits for route authorization',
      (tester) async {
    await Supabase.instance.client.auth.setInitialSession(jsonEncode(
        sessionFixture(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600)));
    final homeGate = Completer<bool>();
    final pushGate = Completer<bool>();
    var homeBuilds = 0;
    var targetBuilds = 0;
    var policyCalls = 0;
    PushNavigation.markNotReady();
    addTearDown(PushNavigation.markNotReady);
    await PushNavigation.handle(
        null, const PushPayload(version: 1, type: 'assignment'),
        fromColdStart: true);
    final router = GoRouter(
      initialLocation: '/splash',
      redirect: (_, state) => authRouteRedirect(
        path: state.uri.path,
        hasSession: Supabase.instance.client.auth.currentSession != null,
        passwordChangeRequired: () {
          policyCalls++;
          return state.uri.path == '/home' ? homeGate.future : pushGate.future;
        },
      ),
      routes: [
        GoRoute(
            path: '/splash',
            builder: (_, __) => SplashScreen(restoreSession: () async => true)),
        GoRoute(
            path: '/home',
            builder: (context, _) {
              homeBuilds++;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                PushNavigation.markReady();
                unawaited(PushNavigation.flushPending(context));
              });
              return const Scaffold(body: Text('Home'));
            }),
        GoRoute(
            path: '/my-diary',
            builder: (_, __) {
              targetBuilds++;
              return const Scaffold(body: Text('Push destination'));
            }),
        GoRoute(path: '/login', builder: (_, __) => const Text('Login')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(homeBuilds, 0);
    expect(targetBuilds, 0);
    expect(policyCalls, 1);
    homeGate.complete(false);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(homeBuilds, greaterThan(0));
    expect(targetBuilds, 0);
    expect(policyCalls, 2);
    pushGate.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Push destination'), findsOneWidget);
    expect(targetBuilds, 1);
  });
}
