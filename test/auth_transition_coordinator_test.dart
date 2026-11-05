import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_transition_coordinator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  late StreamController<AuthState> authEvents;
  late Session session;
  late AuthSessionScope scope;
  setUp(() {
    authEvents = StreamController<AuthState>.broadcast(sync: true);
    session = fakeSession('a');
    scope = AuthSessionScope(
        currentSession: () => session, authEvents: authEvents.stream);
    authEvents.add(AuthState(AuthChangeEvent.initialSession, session));
  });
  tearDown(() async {
    scope.dispose();
    await authEvents.close();
  });
  AuthTransitionOwner owner() => AuthTransitionOwner.capture(scope)!;

  test('logout is single-flight and a later login waits for actual completion',
      () async {
    final coordinator = AuthTransitionCoordinator();
    final gate = Completer<void>();
    final events = <String>[];
    final first = coordinator.logout(owner(), action: () async {
      events.add('logout');
      await gate.future;
      events.add('finished');
    });
    final second = coordinator.logout(owner(), action: () async {
      events.add('duplicate');
    });
    final login = coordinator.run(() async {
      events.add('login');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['logout']);
    gate.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    await login;
    expect(events, ['logout', 'finished', 'login']);
  });
  test('caller timeout does not release a running exclusive transition',
      () async {
    final coordinator = AuthTransitionCoordinator();
    final gate = Completer<void>();
    final logout = coordinator.logout(owner(), action: () => gate.future);
    await expectLater(logout.timeout(const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()));
    var entered = false;
    final login = coordinator.run(() async {
      entered = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(entered, isFalse);
    gate.complete();
    expect(await logout, isTrue);
    await login;
    expect(entered, isTrue);
  });

  test('new session with same uid is a distinct queued logout', () async {
    final coordinator = AuthTransitionCoordinator();
    final gate = Completer<void>();
    final steps = <String>[];
    final first = coordinator.logout(owner(), action: () async {
      steps.add('old');
      await gate.future;
    });
    await Future<void>.delayed(Duration.zero);
    session = fakeSession('a', access: 'new-session');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    final second = coordinator.logout(owner(), action: () async {
      steps.add('new');
    });
    expect(steps, ['old']);
    gate.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(steps, ['old', 'new']);
  });
  test('A to B to A makes queued old logout stale', () async {
    final coordinator = AuthTransitionCoordinator();
    final gate = Completer<void>();
    final earlier = coordinator.run(() => gate.future);
    var invoked = false;
    final logout = coordinator.logout(owner(), action: () async {
      invoked = true;
    });
    session = fakeSession('b');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('a');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    gate.complete();
    await earlier;
    expect(await logout, isFalse);
    expect(invoked, isFalse);
  });
  test('error and disposal do not leak an exclusive lease', () async {
    final coordinator = AuthTransitionCoordinator();
    await expectLater(
        coordinator.logout(owner(),
            action: () async => throw StateError('failed')),
        throwsStateError);
    expect(await coordinator.run(() async => 42), 42);
    final gate = Completer<void>();
    final running = coordinator.run(() => gate.future);
    await Future<void>.delayed(Duration.zero);
    final queued = coordinator.run(() async => 7);
    final expectation = expectLater(queued, throwsStateError);
    coordinator.dispose();
    gate.complete();
    await running;
    await expectation;
  });
}
