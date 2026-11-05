import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/learning/state/team_cache_owner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  test('token refresh invalidates old tickets while allowing new ones',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a', access: 'first');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    expect(TeamCacheOwner.bind(scope, 'team'), isNull);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = TeamCacheOwner.bind(scope, 'team')!;
    final old = owner.capture()!;
    session = fakeSession('a', access: 'refreshed');
    expect(owner.isCurrent(old), isFalse);
    expect(owner.capture(), isNull);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    expect(owner.isCurrent(old), isFalse);
    expect(owner.isCurrent(owner.capture()!), isTrue);
    owner.dispose();
    expect(owner.capture(), isNull);
    scope.dispose();
    await events.close();
  });
  test('A to B to A never revives an old cohort or ticket', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = TeamCacheOwner.bind(scope, 'team')!;
    final ticket = owner.capture()!;
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(owner.capture(), isNull);
    expect(owner.isCurrent(ticket), isFalse);
    final fresh = TeamCacheOwner.bind(scope, 'team')!;
    expect(fresh.isCurrent(ticket), isFalse);
    expect(fresh.isCurrent(fresh.capture()!), isTrue);
    owner.dispose();
    fresh.dispose();
    scope.dispose();
    await events.close();
  });
  test('logout fences new and outstanding tickets immediately', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = TeamCacheOwner.bind(scope, 'team')!;
    final ticket = owner.capture()!;
    scope.invalidateForSignOut();
    expect(owner.capture(), isNull);
    expect(owner.isCurrent(ticket), isFalse);
    owner.dispose();
    scope.dispose();
    await events.close();
  });

  test('same-user sign-in and source closure cannot revive a cohort', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    expect(TeamCacheOwner.bind(scope, ''), isNull);
    final owner = TeamCacheOwner.bind(scope, 'team')!;
    final old = owner.capture()!;
    final otherTeam = TeamCacheOwner.bind(scope, 'other')!;
    expect(otherTeam.isCurrent(old), isFalse);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(owner.capture(), isNull);
    expect(owner.isCurrent(old), isFalse);
    final current = TeamCacheOwner.bind(scope, 'team')!;
    final ticket = current.capture()!;
    await events.close();
    expect(current.isCurrent(ticket), isFalse);
    expect(current.capture(), isNull);
    owner.dispose();
    otherTeam.dispose();
    current.dispose();
    scope.dispose();
  });
}
