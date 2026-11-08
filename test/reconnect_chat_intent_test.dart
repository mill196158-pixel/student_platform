import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/reconnect_chat_intent.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  test('queued SDK refresh prevents capturing a reconnect intent', () async {
    final session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final inner = MockClient((_) async => http.Response('', 500));
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    final pending = gate.send(http.Request('POST',
      Uri.parse('https://example.invalid/auth/v1/token?grant_type=refresh_token')));
    final registry = ReconnectChatIntent.instance;
    registry.bind(scope, gate, () => session);
    final route = MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink());
    expect(gate.activeAuthOperations, 0);
    expect(gate.refreshEntrants, 1);
    expect(registry.register(scope: scope, route: route, chatId:'chat', targetId:'peer', dm:true), isNull);
    gate.block();
    await expectLater(pending, throwsA(isA<Exception>()));
    registry.cancel(); scope.dispose(); await events.close();
  });

  testWidgets('known reconnect keeps exact route intent until online shell', (tester) async {
    final session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final registry = ReconnectChatIntent.instance;
    registry.cancel();
    final gate = RefreshAdmissionClient(MockClient((_) async => http.Response('', 500)),
        backend: Uri.parse('https://example.invalid'));
    registry.bind(scope, gate, () => session);
    final router = GoRouter(initialLocation: '/home',
      observers: [ReconnectNavigationObserver()], routes: [
        GoRoute(path: '/home', builder: (_, __) => const Scaffold(body: Text('home'))),
        GoRoute(path: '/splash', builder: (_, __) => const Scaffold(body: Text('splash'))),
      ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final nav = router.routerDelegate.navigatorKey.currentState!;
    final route = MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('chat')));
    final marker = registry.register(scope: scope, route: route,
      chatId: 'chat', targetId: 'peer', dm: true);
    unawaited(nav.push(route).whenComplete(() => registry.closed(marker)));
    await tester.pumpAndSettle();
    registry.suspendForReconnect();
    router.go('/splash');
    await tester.pumpAndSettle();
    expect(registry.claim(), isNull);
    registry.allowOnlineHome();
    router.go('/home');
    await tester.pumpAndSettle();
    final claim = registry.claim();
    expect(claim?.chatId, 'chat');
    expect(registry.claim(), isNull);
    expect(claim?.current, isTrue);
    router.dispose();
    scope.dispose();
    await events.close();
  });

  testWidgets('user back cancels the intent; sign-in ABA cancels suspended intent', (tester) async {
    var session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final registry = ReconnectChatIntent.instance;
    registry.cancel();
    final gate = RefreshAdmissionClient(MockClient((_) async => http.Response('', 500)),
        backend: Uri.parse('https://example.invalid'));
    registry.bind(scope, gate, () => session);
    final router = GoRouter(initialLocation: '/home', observers: [ReconnectNavigationObserver()],
      routes: [GoRoute(path: '/home', builder: (_, __) => const Scaffold(body: Text('home')))]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final nav = router.routerDelegate.navigatorKey.currentState!;
    var route = MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('chat')));
    var marker = registry.register(scope: scope, route: route,
        chatId: 'chat', targetId: 'peer', dm: true);
    unawaited(nav.push(route).whenComplete(() => registry.closed(marker)));
    await tester.pumpAndSettle();
    nav.pop(); await tester.pumpAndSettle();
    registry.suspendForReconnect();
    expect(registry.claim(), isNull);
    route = MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('chat')));
    marker = registry.register(scope: scope, route: route,
        chatId: 'chat', targetId: 'peer', dm: true);
    unawaited(nav.push(route).whenComplete(() => registry.closed(marker)));
    await tester.pumpAndSettle();
    unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('other')))));
    await tester.pumpAndSettle();
    nav.pop(); await tester.pumpAndSettle();
    registry.suspendForReconnect();
    expect(registry.claim(), isNull);
    nav.pop(); await tester.pumpAndSettle();
    route = MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('chat')));
    marker = registry.register(scope: scope, route: route,
        chatId: 'chat', targetId: 'peer', dm: true);
    unawaited(nav.push(route).whenComplete(() => registry.closed(marker)));
    await tester.pumpAndSettle();
    registry.suspendForReconnect();
    session = fakeSession('other');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('owner');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(registry.claim(), isNull);
    router.dispose(); scope.dispose(); await events.close();
  });
}
