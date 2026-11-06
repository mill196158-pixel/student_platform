import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/local_snapshot_startup.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Session _session(String uid) {
  final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token = '${part({'alg': 'HS256'})}.${part({
    'iss': 'https://example.invalid/auth/v1', 'sub': uid,
    'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'role': 'authenticated', 'aud': 'authenticated', 'iat': now - 60, 'exp': now + 3600,
  })}.sig';
  return Session(accessToken: token, refreshToken: 'local', tokenType: 'bearer',
      user: User(id: uid, appMetadata: const {}, userMetadata: null,
          aud: 'authenticated', createdAt: ''));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reconnect probe stops immediately when sign-out is fenced', () async {
    final session = _session('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final binding = OfflineSessionBinding.fromSession(session, 'https://example.invalid/auth/v1')!;
    expect(isSameLocalSnapshotSession(scope, binding, session), isTrue);
    scope.invalidateForSignOut();
    // The SDK session getter still has the old session, but reconnect must stop.
    expect(isSameLocalSnapshotSession(scope, binding, session), isFalse);
    scope.dispose(); await events.close();
  });
  test('first login after no saved session can later use the same controller', () async {
    Session? session;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(const AuthState(AuthChangeEvent.initialSession, null));
    final caps = SessionCapabilities(scope);
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1',
        restore: () async => SessionRestoreStatus.transportFailure,
        checkPolicy: () async => throw StateError('must not check'));
    expect(await startup.resolve(caps), OfflineStartupResult.denied);
    session = _session('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await startup.resolve(caps), OfflineStartupResult.cacheOnly);
    expect(caps.capture(SessionCapability.cachedRead)?.userId, 'a');
    scope.invalidateForSignOut();
    expect(caps.capture(SessionCapability.cachedRead), isNull);
    expect(await startup.resolve(caps), OfflineStartupResult.denied);
    caps.dispose(); scope.dispose(); await events.close();
  });
  test('cached access waits for startup transport barrier', () async {
    final session = _session('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final drain = Completer<void>();
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1',
        restore: () async => SessionRestoreStatus.transportFailure,
        checkPolicy: () async => throw StateError('must not call policy'),
        onCacheOnly: () => drain.future);
    final result = startup.resolve(caps);
    await Future<void>.delayed(Duration.zero);
    expect(caps.capture(SessionCapability.cachedRead), isNull);
    drain.complete();
    expect(await result, OfflineStartupResult.cacheOnly);
    expect(caps.capture(SessionCapability.cachedRead), isNotNull);
    expect(caps.capture(SessionCapability.mutation), isNull);
    caps.dispose(); scope.dispose(); await events.close();
  });

  test('online is enabled only after live policy allows', () async {
    final session = _session('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final pending = Completer<SettledPolicyStatus>();
    var resumed = false;
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1',
        restore: () async => SessionRestoreStatus.restored,
        checkPolicy: () => pending.future,
        onOnline: () async { resumed = true; });
    final result = startup.resolve(caps);
    await Future<void>.delayed(Duration.zero);
    expect(caps.capture(SessionCapability.mutation), isNull);
    pending.complete(SettledPolicyStatus.allowed);
    expect(await result, OfflineStartupResult.online);
    expect(resumed, isTrue);
    expect(caps.capture(SessionCapability.mutation), isNotNull);
    caps.dispose(); scope.dispose(); await events.close();
  });
  test('offline uses only cached-read capability and late denial revokes it', () async {
    var session = _session('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final pending = Completer<SettledPolicyStatus>();
    var denied = 0;
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1',
        restore: () async => SessionRestoreStatus.restored,
        checkPolicy: () => pending.future, wait: const Duration(milliseconds: 10),
        onLateDenial: (_) => denied++);
    expect(await startup.resolve(caps), OfflineStartupResult.cacheOnly);
    expect(caps.capture(SessionCapability.cachedRead), isNotNull);
    expect(caps.capture(SessionCapability.mutation), isNull);
    pending.complete(SettledPolicyStatus.denied);
    await Future<void>.delayed(Duration.zero);
    expect(caps.mode, SessionCapabilityMode.blocked);
    expect(denied, 1);
    caps.dispose(); scope.dispose(); await events.close();
  });

  test('late denial is not ignored by a later attempt using the same session', () async {
    final session = _session('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final first = Completer<SettledPolicyStatus>();
    var checks = 0;
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1',
        restore: () async => SessionRestoreStatus.restored,
        checkPolicy: () => ++checks == 1 ? first.future : Future.value(SettledPolicyStatus.allowed),
        wait: const Duration(milliseconds: 10));
    expect(await startup.resolve(caps), OfflineStartupResult.cacheOnly);
    expect(await startup.resolve(caps), OfflineStartupResult.online);
    first.complete(SettledPolicyStatus.denied);
    await Future<void>.delayed(Duration.zero);
    expect(caps.mode, SessionCapabilityMode.blocked);
    caps.dispose(); scope.dispose(); await events.close();
  });

  test('a delayed result cannot reveal data after account change', () async {
    var session = _session('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final pending = Completer<SettledPolicyStatus>();
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1',
        restore: () async => SessionRestoreStatus.restored,
        checkPolicy: () => pending.future, wait: const Duration(seconds: 1));
    final result = startup.resolve(caps);
    await Future<void>.delayed(Duration.zero);
    session = _session('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    pending.complete(SettledPolicyStatus.unavailable);
    expect(await result, OfflineStartupResult.unavailable);
    expect(caps.capture(SessionCapability.cachedRead), isNull);
    caps.dispose(); scope.dispose(); await events.close();
  });
}
