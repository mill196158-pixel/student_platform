import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

bool grant(SessionCapabilities capabilities, SessionCapabilityMode mode,
        AuthOperationScope owner) =>
    capabilities.grant(mode, capabilities.beginAuthorization(owner)!);

void main() {
  test('cache-only permits reads from cache and invalidates earlier writes',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final session = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final capabilities = SessionCapabilities(session);
    final owner = session.capture()!;
    expect(grant(capabilities, SessionCapabilityMode.online, owner), isTrue);
    final oldWrite = capabilities.capture(SessionCapability.mutation)!;
    expect(grant(capabilities, SessionCapabilityMode.cacheOnly, owner), isTrue);
    expect(capabilities.permits(oldWrite, SessionCapability.mutation), isFalse);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect(capabilities.capture(SessionCapability.networkRead), isNull);
    expect(capabilities.capture(SessionCapability.background), isNull);
    expect(capabilities.capture(SessionCapability.cachedRead), isNotNull);
    final read = capabilities.capture(SessionCapability.cachedRead)!;
    expect(capabilities.permits(read, SessionCapability.mutation), isFalse);
    capabilities.dispose();
    session.dispose();
    await events.close();
  });

  test('credential changes, logout and disposal revoke permits synchronously',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var current = fakeSession('a');
    final session = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final capabilities = SessionCapabilities(session);
    grant(capabilities, SessionCapabilityMode.online, session.capture()!);
    final permit = capabilities.capture(SessionCapability.mutation)!;
    current = fakeSession('a', access: 'new');
    expect(capabilities.permits(permit, SessionCapability.mutation), isFalse);
    expect(capabilities.mode, SessionCapabilityMode.blocked);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    expect(capabilities.mode, SessionCapabilityMode.blocked);
    grant(capabilities, SessionCapabilityMode.online, session.capture()!);
    final newer = capabilities.capture(SessionCapability.cachedRead)!;
    session.invalidateForSignOut();
    expect(capabilities.permits(newer, SessionCapability.cachedRead), isFalse);
    expect(capabilities.mode, SessionCapabilityMode.blocked);
    capabilities.dispose();
    expect(capabilities.permits(newer, SessionCapability.cachedRead), isFalse);
    session.dispose();
    await events.close();
  });

  test('permits are bound to the instance and mode revision', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final session = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final a = SessionCapabilities(session);
    final b = SessionCapabilities(session);
    final owner = session.capture()!;
    grant(a, SessionCapabilityMode.online, owner);
    grant(b, SessionCapabilityMode.online, owner);
    final old = a.capture(SessionCapability.cachedRead)!;
    expect(b.permits(old, SessionCapability.cachedRead), isFalse);
    grant(a, SessionCapabilityMode.online, owner);
    expect(a.permits(old, SessionCapability.cachedRead), isFalse);
    final latest = a.capture(SessionCapability.cachedRead)!;
    a.block();
    expect(a.permits(latest, SessionCapability.cachedRead), isFalse);
    a.dispose();
    b.dispose();
    session.dispose();
    await events.close();
  });

  test('late authorization cannot undo a block or newer attempt', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final session = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final capabilities = SessionCapabilities(session);
    final owner = session.capture()!;
    final old = capabilities.beginAuthorization(owner)!;
    capabilities.block();
    expect(capabilities.grant(SessionCapabilityMode.online, old), isFalse);
    final earlier = capabilities.beginAuthorization(owner)!;
    final newer = capabilities.beginAuthorization(owner)!;
    expect(capabilities.grant(SessionCapabilityMode.online, earlier), isFalse);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly, newer), isTrue);
    expect(capabilities.grant(SessionCapabilityMode.online, newer), isFalse);
    capabilities.dispose();
    session.dispose();
    await events.close();
  });

  test('a reentrant block cannot make an old authorization current', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final session = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final capabilities = SessionCapabilities(session);
    var first = true;
    capabilities.addListener(() {
      if (first) {
        first = false;
        capabilities.block();
      }
    });
    final attempt = capabilities.beginAuthorization(session.capture()!)!;
    expect(capabilities.grant(SessionCapabilityMode.online, attempt), isFalse);
    expect(capabilities.mode, SessionCapabilityMode.blocked);
    capabilities.dispose();
    session.dispose();
    await events.close();
  });

  test('a nested authorization supersedes the outer attempt', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('a');
    final session = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final capabilities = SessionCapabilities(session);
    final owner = session.capture()!;
    CapabilityAuthorizationAttempt? nested;
    var first = true;
    capabilities.addListener(() {
      if (first) {
        first = false;
        nested = capabilities.beginAuthorization(owner);
      }
    });
    final outer = capabilities.beginAuthorization(owner)!;
    expect(capabilities.grant(SessionCapabilityMode.online, outer), isFalse);
    expect(
        capabilities.grant(SessionCapabilityMode.cacheOnly, nested!), isTrue);
    capabilities.dispose();
    session.dispose();
    await events.close();
  });
}
