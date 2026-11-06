import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/guarded_policy_redirect.dart';
import 'package:student_platform/src/core/live_policy_grant_bridge.dart';
import 'package:student_platform/src/core/offline_policy_grant_host.dart';
import 'package:student_platform/src/core/offline_policy_grant_store.dart';
import 'package:student_platform/src/ui/splash/splash_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;
import 'offline_policy_grant_store_test.dart' show MemoryStorage;

void main() {
  late StreamController<AuthState> events;
  late Session session;
  late AuthSessionScope scope;
  late OfflinePolicyGrantStore store;
  late OfflinePolicyGrantAccess access;
  setUp(() {
    events = StreamController<AuthState>.broadcast(sync: true);
    session = fakeSession('a');
    scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    store = OfflinePolicyGrantStore(
        session: scope, currentBinding: () => null, storage: MemoryStorage());
  });
  tearDown(() async {
    store.dispose();
    scope.dispose();
    await events.close();
  });
  OfflinePolicyGrantAccess makeAccess(Future<bool> Function() policy) {
    final bridge = LivePolicyGrantBridge(
        scope: scope,
        store: store,
        currentBinding: () => null,
        readLivePolicy: policy);
    return OfflinePolicyGrantAccess(
        scope, store, bridge, () => session, 'issuer');
  }

  Future<String?> redirect(String path) => guardedPolicyRedirect(
      path: path, hasSession: () => true, currentAccess: () => access);

  test('public paths do not check policy', () async {
    access = makeAccess(() async => throw StateError('must not run'));
    for (final path in ['/guest', '/login', '/splash', '/change-password']) {
      expect(await redirect(path), isNull);
    }
  });

  test('missing session routes to login without checking policy', () async {
    expect(
        await guardedPolicyRedirect(
            path: '/home',
            hasSession: () => false,
            currentAccess: () => throw StateError('must not run')),
        '/login');
  });

  test('unready session does not grant entry', () async {
    expect(
        await guardedPolicyRedirect(
            path: '/home', hasSession: () => true, currentAccess: () => null),
        '/splash?retry=1');
  });
  test('late old account outcomes cannot decide the new account route',
      () async {
    for (final outcome in ['allow', 'change', 'denied']) {
      session = fakeSession('a', access: 'a-$outcome');
      events.add(AuthState(AuthChangeEvent.signedIn, session));
      final delayed = Completer<bool>();
      access = makeAccess(() => delayed.future);
      final result = redirect('/home');
      session = fakeSession('b', access: 'b-$outcome');
      events.add(AuthState(AuthChangeEvent.signedIn, session));
      access = makeAccess(() async => false);
      if (outcome == 'denied') {
        delayed
            .completeError(const AuthApiException('denied', statusCode: '401'));
      } else {
        delayed.complete(outcome == 'change');
      }
      expect(await result, isNull);
    }
  });
  test('replaced bridge decision is retried', () async {
    final delayed = Completer<bool>();
    access = makeAccess(() => delayed.future);
    final result = redirect('/home');
    access = makeAccess(() async => true);
    delayed.complete(false);
    expect(await result, '/change-password');
  });
  test('online failure cannot grant access', () async {
    access = makeAccess(() async => throw TimeoutException('offline'));
    expect(await redirect('/home'), '/splash?retry=1&offline=1');
  });

  test('confirmed policy rejection still routes to login', () async {
    access = makeAccess(() async =>
        throw const AuthApiException('denied', statusCode: '401'));
    expect(await redirect('/home'), '/login');
  });

  testWidgets('policy network failure offers retry and rechecks policy',
      (tester) async {
    var calls = 0;
    var homeBuilds = 0;
    final router = GoRouter(
      initialLocation: '/home',
      redirect: (context, state) => guardedPolicyRedirect(
          path: state.uri.path,
          hasSession: () => true,
          currentAccess: () => context.mounted
              ? OfflinePolicyGrantHost.maybeRead(context)
              : null),
      routes: [
        GoRoute(path: '/home', builder: (_, __) {
          homeBuilds++;
          return const Scaffold(body: Text('home'));
        }),
        GoRoute(
          path: '/splash',
          builder: (_, state) {
            final manual = state.uri.queryParameters['retry'] == '1';
            final offline = state.uri.queryParameters['offline'] == '1';
            return SplashScreen(
              key: ValueKey('$manual:$offline'),
              manualRetry: manual,
              initialNetworkUnavailable: offline,
              restoreSession: () async => true,
            );
          },
        ),
        GoRoute(path: '/login', builder: (_, __) => const Scaffold(body: Text('login'))),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(OfflinePolicyGrantHost(
      source: scope,
      currentSession: () => session,
      issuer: 'issuer',
      storage: MemoryStorage(),
      readLivePolicy: () async {
        if (++calls < 3) throw TimeoutException('offline');
        return false;
      },
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
    expect(homeBuilds, 0);
    expect(find.text('Нет соединения.'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(homeBuilds, 0);
    expect(find.text('Повторить'), findsOneWidget);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.text('home'), findsOneWidget);
  });

  test('newer check invalidates an already completed allow decision', () async {
    final first = Completer<bool>();
    var calls = 0;
    access = makeAccess(() => ++calls == 1 ? first.future : Future.value(true));
    first.future.then<void>((_) async {
      try {
        await access.bridge.check();
      } on PolicyCheckStale {
        // The redirect may itself supersede this concurrent check.
      }
    });
    final result = redirect('/home');
    first.complete(false);
    expect(await result, '/change-password');
    expect(calls, greaterThanOrEqualTo(3));
  });

  testWidgets('router uses host and ignores delayed previous account',
      (tester) async {
    final first = Completer<bool>();
    var calls = 0;
    Future<bool> policy() => ++calls == 1 ? first.future : Future.value(false);
    final router = GoRouter(
        initialLocation: '/home',
        redirect: (context, state) => guardedPolicyRedirect(
            path: state.uri.path,
            hasSession: () => true,
            currentAccess: () => context.mounted
                ? OfflinePolicyGrantHost.maybeRead(context)
                : null),
        routes: [
          for (final name in ['home', 'login', 'splash', 'change-password'])
            GoRoute(
                path: '/$name', builder: (_, __) => Scaffold(body: Text(name))),
        ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(OfflinePolicyGrantHost(
        source: scope,
        currentSession: () => session,
        issuer: 'issuer',
        storage: MemoryStorage(),
        readLivePolicy: policy,
        child: MaterialApp.router(routerConfig: router)));
    await tester.pump();
    expect(calls, 1);
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    first.completeError(const AuthApiException('denied', statusCode: '401'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(find.text('login'), findsNothing);
    expect(calls, 2);
  });

  testWidgets('unready scope shows real retry screen without a route loop',
      (tester) async {
    var restores = 0;
    final router = GoRouter(
      initialLocation: '/splash',
      redirect: (_, state) => guardedPolicyRedirect(
          path: state.uri.path,
          hasSession: () => true,
          currentAccess: () => null),
      routes: [
        GoRoute(
            path: '/home',
            builder: (_, __) => const Scaffold(body: Text('home'))),
        GoRoute(
            path: '/splash',
            builder: (_, state) => SplashScreen(
                  key: ValueKey(state.uri.queryParameters['retry'] == '1'),
                  manualRetry: state.uri.queryParameters['retry'] == '1',
                  restoreSession: () async {
                    restores++;
                    return true;
                  },
                )),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('Повторить'), findsOneWidget);
    expect(restores, 1);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(restores, 2);
    expect(find.text('Повторить'), findsOneWidget);
  });
}
