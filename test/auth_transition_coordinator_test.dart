import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_transition_coordinator.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
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

  Session boundSession(String uid, String sid, String nonce) {
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return fakeSession(uid,
        access: '${part({'alg': 'HS256'})}.${part({
              'iss': 'https://backend.test/auth/v1',
              'sub': uid,
              'session_id': sid,
              'role': 'authenticated',
              'aud': 'authenticated',
              'iat': now - 60,
              'exp': now + 3600,
              'nonce': nonce,
            })}.sig',
        refresh: 'refresh-$nonce');
  }

  test('same-session token refresh does not strand logout fences', () async {
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    session = boundSession('a', sid, 'before');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    final identity =
        LogoutSessionIdentity(session, 'https://backend.test/auth/v1');
    var expectedGeneration = scope.generation;
    final started = Completer<void>(), resume = Completer<void>();
    var signedOut = false;
    final result = runLogoutCleanup(
      isOwnerCurrent: () =>
          identity.matches(session) && scope.generation == expectedGeneration,
      memoryFence: () {
        expectedGeneration++;
        scope.invalidateForSignOut();
      },
      cleanups: [
        () async {
          started.complete();
          await resume.future;
        }
      ],
      signOut: () async {
        signedOut = true;
      },
      clearSession: () {},
    );
    await started.future;
    session = boundSession('a', sid, 'after');
    authEvents.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    expect(scope.capture(), isNull);
    resume.complete();
    expect(await result, LogoutCleanupResult.signedOut);
    expect(signedOut, isTrue);
  });

  test('logout identity rejects foreign session, invalid JWT and ABA', () {
    const first = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const other = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    session = boundSession('a', first, 'one');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    final owner =
        LogoutSessionIdentity(session, 'https://backend.test/auth/v1');
    final generation = scope.generation;
    expect(owner.matches(boundSession('a', first, 'refreshed')), isTrue);
    expect(owner.matches(boundSession('a', other, 'foreign')), isFalse);
    expect(owner.matches(fakeSession('a', access: 'invalid')), isFalse);
    session = boundSession('b', other, 'b');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    session = boundSession('a', first, 'again');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(owner.matches(session), isTrue);
    expect(scope.generation == generation, isFalse);
  });

  test('retry-only owner accepts refresh but never restores read authority',
      () {
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    session = boundSession('a', sid, 'one');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    final identity =
        LogoutSessionIdentity(session, 'https://backend.test/auth/v1');
    scope.invalidateForSignOut();
    final retry = LogoutRetryOwner.capture(scope, identity, session)!;
    expect(scope.capture(), isNull);
    session = boundSession('a', sid, 'refreshed');
    authEvents.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    expect(retry.matches(scope, session), isTrue);
    expect(scope.capture(), isNull);
    expect(retry.matches(scope, fakeSession('a', access: 'invalid')), isFalse);
    session = boundSession('b', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'b');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    session = boundSession('a', sid, 'return');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(retry.matches(scope, session), isFalse);
    expect(scope.capture(), isNull);
  });

  test('failed durable logout can retry without re-enabling session scope',
      () async {
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    session = boundSession('a', sid, 'one');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    final identity =
        LogoutSessionIdentity(session, 'https://backend.test/auth/v1');
    var signedOut = false;
    final first = await runLogoutCleanup(
      memoryFence: scope.invalidateForSignOut,
      durableRevoke: () async => false,
      cleanups: [() async => fail('must not clean')],
      signOut: () async => fail('must not sign out'),
      clearSession: () => fail('must not clear'),
    );
    expect(first, LogoutCleanupResult.blockedBeforeSignOut);
    final retry = LogoutRetryOwner.capture(scope, identity, session)!;
    expect(scope.capture(), isNull);
    session = boundSession('a', sid, 'refreshed');
    authEvents.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    expect(retry.matches(scope, session), isTrue);
    final second = await runLogoutCleanup(
      memoryFence: scope.invalidateForSignOut,
      durableRevoke: () async => true,
      cleanups: [],
      signOut: () async {
        signedOut = true;
      },
      clearSession: () {},
    );
    expect(second, LogoutCleanupResult.signedOut);
    expect(signedOut, isTrue);
    expect(scope.capture(), isNull);
  });

  test('retry-only owner is not issued for an unparseable token', () {
    session = fakeSession('a', access: 'invalid');
    authEvents.add(AuthState(AuthChangeEvent.signedIn, session));
    final identity =
        LogoutSessionIdentity(session, 'https://backend.test/auth/v1');
    expect(identity.matches(session), isTrue); // Exact-token fallback only.
    scope.invalidateForSignOut();
    expect(LogoutRetryOwner.capture(scope, identity, session), isNull);
    expect(scope.capture(), isNull);
  });

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
