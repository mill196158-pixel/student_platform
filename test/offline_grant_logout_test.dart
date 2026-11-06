import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/live_policy_grant_bridge.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
import 'package:student_platform/src/core/offline_grant_logout.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_policy_grant_host.dart';
import 'package:student_platform/src/core/offline_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;
import 'offline_policy_grant_store_test.dart' show MemoryStorage;

class ThrowingRemoveStorage extends MemoryStorage {
  @override
  Future<bool> remove(String key) => Future.error(StateError('disk error'));
}

void main() {
  const issuer = 'https://project.example/auth/v1';
  final now = DateTime.utc(2026, 11, 5, 12);
  Session sessionFor(String user, String sid) {
    final claims = {
      'iss': issuer,
      'sub': user,
      'session_id': sid,
      'role': 'authenticated',
      'aud': 'authenticated',
      'iat': now.subtract(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
          1000,
      'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000
    };
    final payload =
        base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
    return fakeSession(user, access: 'e30.$payload.signature');
  }

  late Session session;
  late StreamController<AuthState> events;
  late AuthSessionScope scope;
  late MemoryStorage storage;
  late OfflinePolicyGrantStore store;
  late OfflinePolicyGrantAccess access;
  setUp(() {
    session = sessionFor('a', '12345678-1234-1234-1234-123456789012');
    events = StreamController<AuthState>.broadcast(sync: true);
    scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    OfflineSessionBinding? binding() =>
        OfflineSessionBinding.fromSession(session, issuer);
    storage = MemoryStorage();
    store = OfflinePolicyGrantStore(
        session: scope, currentBinding: binding, storage: storage);
    final bridge = LivePolicyGrantBridge(
        scope: scope,
        store: store,
        currentBinding: binding,
        readLivePolicy: () async => false);
    access =
        OfflinePolicyGrantAccess(scope, store, bridge, () => session, issuer);
  });
  tearDown(() async {
    store.dispose();
    scope.dispose();
    await events.close();
  });

  Future<void> seed() async {
    final binding = access.currentBinding()!;
    final attempt = store.beginLiveCheck(scope.capture()!, binding)!;
    expect(
        await store.saveAfterLiveCheck(
            attempt,
            OfflinePolicyGrant(
                issuer: issuer,
                userId: binding.userId,
                sessionId: binding.sessionId,
                checkedAt: now,
                validUntil: now.add(const Duration(minutes: 30)))),
        isTrue);
  }

  test('invalidates synchronously and removes saved grant', () async {
    await seed();
    final owner = scope.capture()!;
    final revoke = beginOfflineGrantLogout(
        access: access, invalidate: scope.invalidateForSignOut);
    expect(scope.isCurrent(owner), isFalse);
    expect(await revoke, isTrue);
    expect(storage.values, isEmpty);
  });
  test('failed removal is reported as incomplete but signout still runs',
      () async {
    await seed();
    storage.failRemove = true;
    var signedOut = false;
    final revoke = beginOfflineGrantLogout(
        access: access, invalidate: scope.invalidateForSignOut);
    final complete = await runLogoutCleanup(
        cleanups: [
          () async {
            if (!await revoke) throw StateError('failed');
          }
        ],
        signOut: () async {
          signedOut = true;
        },
        clearSession: () {});
    expect(complete, LogoutCleanupResult.signedOutCleanupIncomplete);
    expect(signedOut, isTrue);
  });
  test('hanging removal times out without blocking signout and continues later',
      () async {
    await seed();
    final gate = Completer<void>();
    storage.removeGates.add(gate);
    final revoke = beginOfflineGrantLogout(
        access: access,
        invalidate: scope.invalidateForSignOut,
        timeout: const Duration(milliseconds: 10));
    var signedOut = false;
    final complete = await runLogoutCleanup(
        cleanups: [
          () async {
            if (!await revoke) throw StateError('timeout');
          }
        ],
        signOut: () async {
          signedOut = true;
        },
        clearSession: () {});
    expect(complete, LogoutCleanupResult.signedOutCleanupIncomplete);
    expect(signedOut, isTrue);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(storage.values, isEmpty);
  });

  test('delayed save cannot revive grant after logout begins', () async {
    final binding = access.currentBinding()!;
    final attempt = store.beginLiveCheck(scope.capture()!, binding)!;
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final save = store.saveAfterLiveCheck(
        attempt,
        OfflinePolicyGrant(
            issuer: issuer,
            userId: binding.userId,
            sessionId: binding.sessionId,
            checkedAt: now,
            validUntil: now.add(const Duration(minutes: 30))));
    await storage.writeEntered!.future;
    final revoke = beginOfflineGrantLogout(
        access: access, invalidate: scope.invalidateForSignOut);
    storage.writeRelease!.complete();
    await save;
    expect(await revoke, isTrue);
    expect(storage.values, isEmpty);
  });

  test('throwing storage is reported without escaping asynchronously',
      () async {
    final throwing = ThrowingRemoveStorage();
    final replacement = OfflinePolicyGrantStore(
        session: scope,
        currentBinding: access.currentBinding,
        storage: throwing);
    final replacementAccess = OfflinePolicyGrantAccess(
        scope,
        replacement,
        LivePolicyGrantBridge(
            scope: scope,
            store: replacement,
            currentBinding: access.currentBinding,
            readLivePolicy: () async => false),
        () => session,
        issuer);
    expect(
        await beginOfflineGrantLogout(
            access: replacementAccess, invalidate: scope.invalidateForSignOut),
        isFalse);
    replacement.dispose();
  });

  test('old account removal does not delete the new account grant', () async {
    await seed();
    final gate = Completer<void>();
    storage.removeGates.add(gate);
    final revoke = beginOfflineGrantLogout(
        access: access, invalidate: scope.invalidateForSignOut);
    events.add(AuthState(AuthChangeEvent.signedOut, null));
    session = sessionFor('b', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await seed();
    gate.complete();
    expect(await revoke, isTrue);
    final b = access.currentBinding()!;
    expect(await store.read(scope.capture()!, b), isNotNull);
    expect(storage.values.length, 1);
  });
}
