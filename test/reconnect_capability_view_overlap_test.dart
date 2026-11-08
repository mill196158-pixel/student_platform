import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/qa_capability_view.dart';
import 'package:student_platform/src/core/qa_online_side_effect_coordinator.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  testWidgets('disposing old cache shell does not close newer online barrier', (tester) async {
    final session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync:true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents:events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    final coordinator = QaOnlineSideEffectCoordinator();
    var oldOnline = 0;
    Widget view(Key key) => QaCapabilityView(key:key, capabilities:caps, coordinator:coordinator,
      suppressOffstageCachePromotion:true,
      onlineBuilder: (_, __) { if (key == const ValueKey('old')) oldOnline++; return const Text('online'); },
      cachedBuilder: (_) => const Text('cache'), blockedBuilder: (_) => const Text('blocked'));
    final navKey = GlobalKey<NavigatorState>();
    Route<dynamic>? oldRoute;
    await tester.pumpWidget(MaterialApp(navigatorKey:navKey, home: Builder(builder:(context) {
      oldRoute = ModalRoute.of(context);
      return view(const ValueKey('old'));
    })));
    caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(scope.capture()!)!);
    unawaited(navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => view(const ValueKey('new')))));
    await tester.pump();
    final barrier = coordinator.barrier;
    expect(barrier, isNotNull);
    expect(barrier!.isOpen, isTrue);
    expect(oldOnline, 0);
    navKey.currentState!.removeRoute(oldRoute!);
    await tester.pump();
    expect(barrier.isOpen, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(barrier.isOpen, isFalse);
    caps.dispose(); scope.dispose(); await events.close();
  });

  testWidgets('denial closes current online barrier even with old cached route offstage', (tester) async {
    final session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync:true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents:events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    final coordinator = QaOnlineSideEffectCoordinator();
    Widget view() => QaCapabilityView(capabilities:caps, coordinator:coordinator,
      suppressOffstageCachePromotion:true, onlineBuilder: (_, __) => const Text('online'),
      cachedBuilder: (_) => const Text('cache'), blockedBuilder: (_) => const Text('blocked'));
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey:navKey, home:view()));
    caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(scope.capture()!)!);
    unawaited(navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => view())));
    await tester.pump();
    final barrier = coordinator.barrier!;
    expect(barrier.isOpen, isTrue);
    caps.block();
    expect(barrier.isOpen, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose(); scope.dispose(); await events.close();
  });
}
