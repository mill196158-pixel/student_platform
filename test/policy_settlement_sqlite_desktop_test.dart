import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'real SQLite prior grant CAS survives reopen but unknown pending stays blocked',
      () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('student_policy_sqlite_');
    final path = '${dir.path}/policy.db';
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    var binding = OfflineSessionBinding(
        issuer: 'https://a.invalid/auth/v1',
        userId: 'a',
        sessionId: 'sid',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    var db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    SqlitePolicyGrantStore make() => SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    var store = make();
    var attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: binding.issuer,
                userId: binding.userId,
                sessionId: binding.sessionId,
                checkedAt: now,
                validUntil: now.add(const Duration(hours: 2)))),
        isTrue);
    final prior = (await store.capturePriorGrant(scope.capture()!, binding))!;
    await store.beginLiveCheck(scope.capture()!, binding);
    final latest = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(
        await store.restoreAfterSettledTransportFailure(prior, latest), isTrue);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    await db.close();
    db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    store = make();
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    final stalePrior =
        (await store.capturePriorGrant(scope.capture()!, binding))!;
    final staleAttempt =
        (await store.beginLiveCheck(scope.capture()!, binding))!;
    session = fakeSession('a', access: 'other-session-token');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    binding = OfflineSessionBinding(
        issuer: binding.issuer,
        userId: binding.userId,
        sessionId: 'sid-b',
        notBefore: binding.notBefore,
        expiresAt: binding.expiresAt);
    final fresh = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(
        await store.saveAllowed(
            fresh,
            OfflinePolicyGrant(
                issuer: binding.issuer,
                userId: binding.userId,
                sessionId: binding.sessionId,
                checkedAt: now,
                validUntil: now.add(const Duration(hours: 2)))),
        isTrue);
    expect(
        await store.restoreAfterSettledTransportFailure(
            stalePrior, staleAttempt),
        isFalse);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    final pendingPrior =
        await store.capturePriorGrant(scope.capture()!, binding);
    expect(pendingPrior, isNotNull);
    await store.beginLiveCheck(scope.capture()!, binding);
    await db.close();
    db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    store = make();
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
    scope.dispose();
    await events.close();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  });
}
