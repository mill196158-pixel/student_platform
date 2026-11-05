import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Session fakeSession(String uid,
        {String access = 'access', String refresh = 'refresh'}) =>
    Session(
        accessToken: access,
        refreshToken: refresh,
        tokenType: 'bearer',
        user: User(
            id: uid,
            appMetadata: const {},
            userMetadata: null,
            aud: '',
            createdAt: ''));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('requires initial auth event and accepts a silent equivalent clone',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    expect(source.capture(), isNull);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    await source.ready;
    final scope = source.capture()!;
    current = fakeSession('a');
    expect(source.isCurrent(scope), isTrue);
    expect(source.capture(), scope);
    expect(source.capture().hashCode, scope.hashCode);
    source.dispose();
    await events.close();
  });

  test('credential change is rejected before an asynchronous event arrives',
      () async {
    final events = StreamController<AuthState>.broadcast();
    var current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    await source.ready;
    final old = source.capture()!;
    current = fakeSession('a', access: 'new');
    expect(source.isCurrent(old), isFalse);
    expect(source.capture(), isNull);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    await Future<void>.delayed(Duration.zero);
    expect(source.capture(), isNotNull);
    expect(source.isCurrent(old), isFalse);
    source.dispose();
    await events.close();
  });

  test('logout intent and same-user re-login invalidate old scopes', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    Session? current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final old = source.capture()!;
    source.invalidateForSignOut();
    expect(source.isCurrent(old), isFalse);
    events.add(AuthState(AuthChangeEvent.signedIn, current));
    expect(source.capture(), isNull);
    current = null;
    events.add(const AuthState(AuthChangeEvent.signedOut, null));
    current = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    expect(source.capture(), isNull);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    expect(source.capture(), isNull);
    events.add(AuthState(AuthChangeEvent.signedIn, current));
    expect(source.isCurrent(old), isFalse);
    expect(source.capture(), isNotNull);
    source.dispose();
    await events.close();
  });

  test('one source cannot accept another source’s scope', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final a = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    final b = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    expect(b.isCurrent(a.capture()!), isFalse);
    a.dispose();
    b.dispose();
    await events.close();
  });

  test('initial stream error permits only unchanged baseline identity',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.addError(TimeoutException('offline'), StackTrace.current);
    await source.ready;
    expect(source.capture(), isNotNull);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    expect(source.capture(), isNotNull);
    source.dispose();
    await events.close();
  });

  test('stream close and disposal release readiness without granting a scope',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    await events.close();
    await source.ready;
    expect(source.capture(), isNull);
    source.dispose();
    final waiting = StreamController<AuthState>.broadcast(sync: true);
    final another = AuthSessionScope(
        currentSession: () => current, authEvents: waiting.stream);
    another.dispose();
    await another.ready;
    expect(another.capture(), isNull);
    await waiting.close();
  });

  test('password recovery and stream closure revoke previously captured work',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final old = source.capture()!;
    events.add(AuthState(AuthChangeEvent.passwordRecovery, current));
    expect(source.isCurrent(old), isFalse);
    final newer = source.capture()!;
    await events.close();
    expect(source.isCurrent(newer), isFalse);
    expect(source.capture(), isNull);
    source.dispose();
  });

  test('listeners observe logout, token rotation and stream closure', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    var notifications = 0;
    source.addListener(() => notifications++);
    current = fakeSession('a', access: 'rotated');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    source.invalidateForSignOut();
    await events.close();
    expect(notifications, 3);
    source.dispose();
  });

  test('opaque scope connects the local cache without exposing credentials',
      () async {
    SharedPreferences.setMockInitialValues({});
    final events = StreamController<AuthState>.broadcast(sync: true);
    var current = fakeSession('a');
    final source = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final cache = HomeSnapshotCache(
      currentUserId: () => source.capture()?.userId,
      sessionGeneration: () => source.generation,
      sessionIdentity: source.capture,
    );
    final original = cache.captureScope('a')!;
    expect(
        await cache.write(
            scope: original,
            section: HomeSnapshotSection.schedule,
            items: [],
            savedAt: DateTime.utc(2026)),
        isTrue);
    expect(await cache.read('a', HomeSnapshotSection.schedule), isNotNull);
    current = fakeSession('a', access: 'rotated');
    expect(
        await cache.write(
            scope: original,
            section: HomeSnapshotSection.schedule,
            items: [],
            savedAt: DateTime.utc(2026)),
        isFalse);
    source.dispose();
    await events.close();
  });
}
