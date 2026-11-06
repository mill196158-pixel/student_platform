import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/qa_capability_view.dart';
import 'package:student_platform/src/core/qa_online_side_effect_coordinator.dart';
import 'package:student_platform/src/core/qa_rotation_navigation_guard.dart';
import 'package:student_platform/src/core/qa_rotation_receipt.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  testWidgets('same-owner receipt restores shell and nested draft, stale proof fails', (tester) async {
    var session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final previous = scope.capture()!;
    expect(caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(previous)!), isTrue);
    final receipt = QaRotationReceipt();
    final refreshStarts = ValueNotifier<int>(0);
    final coordinator = QaOnlineSideEffectCoordinator();
    final router = GoRouter(initialLocation: '/home', routes: [
      GoRoute(path: '/home', builder: (_, __) => QaCapabilityView(
        capabilities: caps, coordinator: coordinator, retainOnlineForRotation: true,
        blockedBuilder: (_) => const Text('blocked'),
        cachedBuilder: (_) => const Text('cached'),
        onlineBuilder: (_, __) => const _Shell(),
      )),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router,
      builder: (_, child) => QaRotationNavigationGuard(
        scope: scope, capabilities: caps, receipt: receipt,
        refreshStarts: refreshStarts, child: child!)));
    await tester.tap(find.text('profile'));
    await tester.pump();
    await tester.tap(find.text('open chat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'draft');
    refreshStarts.value++;
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    // A failed/unfinished refresh has no proof, so the shield remains closed.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TextField), findsNothing);
    receipt.record(previous, previous, caps);
    await tester.pumpAndSettle();
    expect(find.text('draft'), findsOneWidget);
    refreshStarts.value++;
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    session = fakeSession('a', access: 'rotated');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Сессия проверяется.'), findsOneWidget);
    final current = scope.capture()!;
    expect(caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(current)!), isTrue);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    receipt.record(previous, current, caps);
    await tester.pumpAndSettle();
    expect(find.text('draft'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('profile open'), findsOneWidget);
    caps.block();
    await tester.pump();
    expect(find.text('profile open'), findsNothing);
    expect(find.text('Сессия проверяется.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    router.dispose(); coordinator.dispose(); refreshStarts.dispose(); receipt.dispose(); caps.dispose(); scope.dispose();
    await events.close();
  });

  testWidgets('cache-only owner logout covers an already open root route', (tester) async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!), isTrue);
    final receipt = QaRotationReceipt();
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => QaRotationNavigationGuard(
        scope: scope, capabilities: caps, receipt: receipt, child: child!),
      home: const _Shell(),
    ));
    await tester.tap(find.text('profile'));
    await tester.pump();
    await tester.tap(find.text('open chat'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'private draft');
    scope.invalidateForSignOut();
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Сессия проверяется.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    receipt.dispose(); caps.dispose(); scope.dispose(); await events.close();
  });

  testWidgets('overlapping refreshes remain covered even with a receipt', (tester) async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final owner = scope.capture()!;
    expect(caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(owner)!), isTrue);
    final receipt = QaRotationReceipt();
    final starts = ValueNotifier<int>(0);
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => QaRotationNavigationGuard(scope: scope,
        capabilities: caps, receipt: receipt, refreshStarts: starts, child: child!),
      home: const Scaffold(body: Text('private')),
    ));
    starts.value++;
    starts.value++;
    receipt.record(owner, owner, caps);
    await tester.pump();
    expect(find.text('private'), findsNothing);
    expect(find.text('Сессия проверяется.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    starts.dispose(); receipt.dispose(); caps.dispose(); scope.dispose(); await events.close();
  });

  testWidgets('a refresh started before guard mount stays covered', (tester) async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final owner = scope.capture()!;
    expect(caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(owner)!), isTrue);
    final receipt = QaRotationReceipt();
    final starts = ValueNotifier<int>(1);
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => QaRotationNavigationGuard(scope: scope,
        capabilities: caps, receipt: receipt, refreshStarts: starts,
        hasPendingRefresh: () => true, child: child!),
      home: const Scaffold(body: Text('private')),
    ));
    expect(find.text('private'), findsNothing);
    starts.value++;
    receipt.record(owner, owner, caps);
    await tester.pump();
    expect(find.text('private'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    starts.dispose(); receipt.dispose(); caps.dispose(); scope.dispose(); await events.close();
  });
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  bool profile = false;
  @override
  Widget build(BuildContext context) => Scaffold(body: Column(children: [
    Text(profile ? 'profile open' : 'home'),
    TextButton(onPressed: () => setState(() => profile = true), child: const Text('profile')),
    if (profile) TextButton(onPressed: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => Scaffold(appBar: AppBar(), body: const TextField()))),
      child: const Text('open chat')),
  ]));
}
