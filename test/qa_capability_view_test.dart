import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/qa_capability_view.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/qa_online_side_effect_coordinator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  testWidgets('QA shell builds only the current permitted mode', (tester) async {
    var session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    var onlineBuilds = 0, cachedBuilds = 0;
    await tester.pumpWidget(MaterialApp(home: QaCapabilityView(
      capabilities: caps, coordinator: QaOnlineSideEffectCoordinator(),
      onlineBuilder: (_, __) { onlineBuilds++; return const Text('online'); },
      cachedBuilder: (_) { cachedBuilds++; return const Text('cached'); },
      blockedBuilder: (_) => const Text('blocked'))));
    expect(find.text('blocked'), findsOneWidget);
    expect(onlineBuilds, 0);
    caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(scope.capture()!)!);
    await tester.pump();
    expect(find.text('online'), findsOneWidget);
    caps.block();
    await tester.pump();
    expect(find.text('online'), findsNothing);
    expect(find.text('blocked'), findsOneWidget);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    await tester.pump();
    expect(find.text('cached'), findsOneWidget);
    session = fakeSession('a', access: 'other');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await tester.pump();
    expect(find.text('cached'), findsNothing);
    expect(find.text('blocked'), findsOneWidget);
    expect(onlineBuilds, 1);
    expect(cachedBuilds, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
  });

  testWidgets('cache-only shell waits for old online work and teardown', (tester) async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(scope.capture()!)!);
    late OnlineSideEffectBarrier barrier;
    final pending = Completer<void>(), teardown = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: QaCapabilityView(capabilities: caps,
      coordinator: QaOnlineSideEffectCoordinator(),
      onlineBuilder: (_, value) { barrier = value; return const Text('online'); },
      cachedBuilder: (_) => const Text('cached'), blockedBuilder: (_) => const Text('blocked'))));
    final work = barrier.run(() => pending.future);
    barrier.onClose(() { unawaited(barrier.trackTeardown(() => teardown.future)); });
    caps.block();
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    await tester.pump();
    expect(find.text('cached'), findsNothing);
    expect(find.text('blocked'), findsOneWidget);
    pending.complete();
    await work;
    await tester.pump();
    expect(find.text('cached'), findsNothing);
    teardown.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('cached'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose(); scope.dispose(); await events.close();
  });

  testWidgets('remount cannot bypass pending drain from previous shell', (tester) async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope), coordinator = QaOnlineSideEffectCoordinator();
    caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(scope.capture()!)!);
    late OnlineSideEffectBarrier barrier;
    Widget shell() => MaterialApp(home: QaCapabilityView(capabilities: caps, coordinator: coordinator,
      onlineBuilder: (_, value) { barrier = value; return const Text('online'); },
      cachedBuilder: (_) => const Text('cached'), blockedBuilder: (_) => const Text('blocked')));
    await tester.pumpWidget(shell());
    final pending = Completer<void>();
    final work = barrier.run(() => pending.future);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(coordinator.blocked, isTrue);
    caps.block();
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    await tester.pumpWidget(shell());
    expect(find.text('blocked'), findsOneWidget);
    expect(find.text('cached'), findsNothing);
    pending.complete();
    await work;
    await tester.pump();
    await tester.pump();
    expect(find.text('cached'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose(); scope.dispose(); await events.close();
  });
}
