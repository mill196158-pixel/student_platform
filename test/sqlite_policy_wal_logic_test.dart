import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_policy_grant_store.dart';
import 'package:student_platform/src/core/live_policy_grant_bridge.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;
import 'offline_policy_grant_store_test.dart' show MemoryStorage;

/// In-memory SQL contract double: verifies Dart fences, not SQLite durability.
class _Database implements Database, Transaction {
  Map<String, Object?>? owner;
  final grants = <String, Map<String, Object?>>{};
  Future<void> Function()? onRevokeUpdate;

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
      {bool? exclusive}) async {
    final beforeOwner = owner == null ? null : Map<String, Object?>.of(owner!);
    final beforeGrants = {
      for (final entry in grants.entries)
        entry.key: Map<String, Object?>.of(entry.value)
    };
    try {
      return await action(this);
    } catch (_) {
      owner = beforeOwner;
      grants
        ..clear()
        ..addAll(beforeGrants);
      rethrow;
    }
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    final a = arguments!;
    if (sql.startsWith('INSERT OR IGNORE INTO policy_owner')) {
      owner ??= {'epoch': 0, 'live_seq': 0, 'state': a[2], 'last_seen': null};
    } else if (sql.startsWith('INSERT OR REPLACE INTO policy_grant')) {
      grants[a[2] as String] = {
        'owner_epoch': a[3],
        'live_seq': a[4],
        'checked_at': a[5],
        'valid_until': a[6],
        'token_nbf': a[7],
        'token_exp': a[8],
      };
    } else {
      throw StateError('Unexpected insert');
    }
    return 1;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    final a = arguments!;
    final row = owner!;
    if (sql.startsWith(
        "UPDATE policy_owner SET live_seq=live_seq+1,state='revoked'")) {
      row['live_seq'] = (row['live_seq'] as int) + 1;
      row['state'] = 'revoked';
    } else if (sql.startsWith('UPDATE policy_owner SET epoch=epoch+1')) {
      await onRevokeUpdate?.call();
      row['epoch'] = (row['epoch'] as int) + 1;
      row['live_seq'] = (row['live_seq'] as int) + 1;
      row['state'] = a[0];
    } else if (sql.startsWith('UPDATE policy_owner SET state=?,last_seen=?')) {
      if (row['epoch'] != a[4] || row['live_seq'] != a[5]) return 0;
      row['state'] = a[0];
      row['last_seen'] = a[1];
    } else if (sql.startsWith('UPDATE policy_owner SET last_seen=?')) {
      row['last_seen'] = a[0];
    } else {
      throw StateError('Unexpected update');
    }
    return 1;
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    if (sql == 'DELETE FROM policy_grant WHERE issuer=? AND uid=?') {
      final count = grants.length;
      grants.clear();
      return count;
    }
    throw StateError('Unexpected delete');
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    if (sql.contains('FROM policy_owner')) {
      return owner == null ? [] : [Map<String, Object?>.of(owner!)];
    }
    if (sql.contains('FROM policy_grant')) {
      final row = grants[arguments![2]];
      return row == null ? [] : [Map<String, Object?>.of(row)];
    }
    throw StateError('Unexpected query');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HttpClient extends http.BaseClient {
  _HttpClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  test('early refresh admission waits for owner and fails closed', () async {
    var calls = 0;
    final inner = _HttpClient((request) async {
      calls++;
      return http.StreamedResponse(const Stream.empty(), 200);
    });
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://backend.invalid'));
    final request = http.Request(
        'POST',
        Uri.parse(
            'https://backend.invalid/auth/v1/token?grant_type=refresh_token'));
    final pending = gate.send(request);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 0);
    gate.bind(inner);
    expect((await pending).statusCode, 200);
    expect(calls, 1);
    gate.close();
    final blocked = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://backend.invalid'));
    final denied = blocked.send(http.Request(
        'POST',
        Uri.parse(
            'https://backend.invalid/auth/v1/token?grant_type=refresh_token')));
    blocked.block();
    await expectLater(denied, throwsA(isA<http.ClientException>()));
    expect(calls, 1);
    blocked.close();
  });

  test('policy bridge uses the same SQLite owner for permit and logout',
      () async {
    final now = DateTime.now().toUtc();
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final binding = OfflineSessionBinding(
        issuer: 'https://backend.invalid/auth/v1',
        userId: 'a',
        sessionId: 'session-a',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    final db = _Database();
    final sqlite = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    final old = OfflinePolicyGrantStore(
        session: scope,
        currentBinding: () => binding,
        storage: MemoryStorage());
    final bridge = LivePolicyGrantBridge(
        scope: scope,
        store: old,
        sqliteStore: sqlite,
        currentBinding: () => binding,
        readLivePolicy: () async {
          expect(db.owner!['state'], 'revoked');
          return false;
        },
        clock: () => now);
    expect(await bridge.check(), isFalse);
    expect((await sqlite.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    final pause = Completer<void>();
    final entered = Completer<void>();
    db.onRevokeUpdate = () async {
      entered.complete();
      await pause.future;
    };
    var current = true;
    final revoke = sqlite.beginRevoke(binding, stillCurrent: () => current);
    await entered.future;
    current = false;
    pause.complete();
    await expectLater(revoke, throwsA(anything));
    expect(db.owner!['state'], 'active');
    expect(db.grants, isNotEmpty);
    old.dispose();
    sqlite.dispose();
    scope.dispose();
    await events.close();
  });

  test('suspend fences new sends and waits for the in-flight response',
      () async {
    final response = Completer<http.StreamedResponse>();
    var calls = 0;
    final inner = _HttpClient((_) {
      calls++;
      return response.future;
    });
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://backend.invalid'));
    gate.bind(inner);
    http.Request request() => http.Request(
        'POST',
        Uri.parse(
            'https://backend.invalid/auth/v1/token?grant_type=refresh_token'));
    final first = gate.send(request());
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    var drained = false;
    final barrier = gate.suspendAndDrain().then((_) {
      drained = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    await expectLater(
        gate.send(request()), throwsA(isA<RefreshTransportSuppressed>()));
    expect(calls, 1);
    response.complete(http.StreamedResponse(const Stream.empty(), 200));
    await first;
    await barrier;
    expect(drained, isTrue);
    gate.close();
  });

  test('auth gate drains and blocks non-refresh auth sends', () async {
    final response = Completer<http.StreamedResponse>();
    final inner = _HttpClient((_) => response.future);
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://backend.invalid'));
    final send = gate.send(http.Request('POST',
        Uri.parse('https://backend.invalid/auth/v1/logout')));
    expect(gate.nonRefreshAuthRevision, 1);
    expect(gate.activeAuthOperations, 1);
    var drained = false;
    final barrier = gate.suspendAndDrain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    await expectLater(gate.send(http.Request('GET',
        Uri.parse('https://backend.invalid/auth/v1/user'))),
        throwsA(isA<RefreshTransportSuppressed>()));
    response.complete(http.StreamedResponse(const Stream.empty(), 200));
    await send;
    await barrier;
    expect(drained, isTrue);
    expect(gate.activeAuthOperations, 0);
    gate.resume();
    gate.close();
  });

  test('WAL mode must actually be active', () {
    validatePolicyWalMode([
      {'journal_mode': 'wal'}
    ]);
    for (final rows in <List<Map<String, Object?>>>[
      [],
      [
        {'journal_mode': 'delete'}
      ],
      [
        {'journal_mode': 'memory'}
      ],
      [
        {'journal_mode': null}
      ],
      [
        {'journal_mode': 'wal', 'extra': 'value'}
      ],
    ]) {
      expect(() => validatePolicyWalMode(rows), throwsStateError);
    }
  });
  test('pending survives coordinator recreation and B cannot revive A',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.utc(2026, 11, 6);
    OfflineSessionBinding binding(String sid) => OfflineSessionBinding(
        issuer: 'https://backend.invalid/auth/v1',
        userId: 'a',
        sessionId: sid,
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    var current = binding('session-a');
    final db = _Database();
    SqlitePolicyGrantStore makeStore() => SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => current,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    OfflinePolicyGrant grant() => OfflinePolicyGrant(
        issuer: current.issuer,
        userId: current.userId,
        sessionId: current.sessionId,
        checkedAt: now,
        validUntil: now.add(const Duration(minutes: 30)));
    var store = makeStore();
    final initial = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect(await store.saveAllowed(initial, grant()), isTrue);
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.found);
    final pending = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.blocked);
    store.dispose();
    store = makeStore();
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.blocked);
    session = fakeSession('a', access: 'second-session');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    current = binding('session-b');
    final newer = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect(await store.saveAllowed(newer, grant()), isTrue);
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    current = binding('session-a');
    expect(await store.saveAllowed(pending, grant()), isFalse);
    store.dispose();
    store = makeStore();
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.blocked);
    store.dispose();
    scope.dispose();
    await events.close();
  });

  test('late A denial cannot revoke newer B of the same uid', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.utc(2026, 11, 6);
    OfflineSessionBinding binding(String sid) => OfflineSessionBinding(
        issuer: 'https://backend.invalid/auth/v1',
        userId: 'a',
        sessionId: sid,
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    var current = binding('session-a');
    final db = _Database();
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => current,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    final old = (await store.beginLiveCheck(scope.capture()!, current))!;
    session = fakeSession('a', access: 'new');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    current = binding('session-b');
    final fresh = (await store.beginLiveCheck(scope.capture()!, current))!;
    final grant = OfflinePolicyGrant(
        issuer: current.issuer,
        userId: current.userId,
        sessionId: current.sessionId,
        checkedAt: now,
        validUntil: now.add(const Duration(hours: 1)));
    expect(await store.saveAllowed(fresh, grant), isTrue);
    expect(await store.revokeAfterLiveCheck(old), isFalse);
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.found);
    final denial = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect(await store.revokeAfterLiveCheck(denial), isTrue);
    expect(await store.revokeAfterLiveCheck(denial), isFalse);
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.blocked);
    store.dispose();
    scope.dispose();
    await events.close();
  });

  test('refresh fences before dispatch; a late A 401 cannot revoke B',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a', refresh: 'synthetic-secret');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.utc(2026, 11, 6);
    OfflineSessionBinding binding(String sid) => OfflineSessionBinding(
        issuer: 'https://backend.invalid/auth/v1',
        userId: 'a',
        sessionId: sid,
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    var current = binding('session-a');
    final db = _Database();
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => current,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    final entered = Completer<void>();
    final response = Completer<http.StreamedResponse>();
    final transport = CoordinatedRefreshClient.forTesting(
        _HttpClient((request) {
      expect(db.owner!['state'], 'revoked');
      expect(request.followRedirects, isFalse);
      entered.complete();
      return response.future;
    }), store, Uri.parse('https://backend.invalid'),
        currentRefreshToken: () => session.refreshToken);
    final request = http.Request(
        'POST',
        Uri.parse(
            'https://backend.invalid/auth/v1/token?grant_type=refresh_token'));
    request.body = jsonEncode({'refresh_token': 'synthetic-secret'});
    final pending = transport.send(request);
    final rejected = pending.then<Object?>((_) => null,
        onError: (Object error, StackTrace _) => error);
    await entered.future;
    session = fakeSession('a', access: 'session-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    current = binding('session-b');
    final fresh = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect(
        await store.saveAllowed(
            fresh,
            OfflinePolicyGrant(
                issuer: current.issuer,
                userId: current.userId,
                sessionId: current.sessionId,
                checkedAt: now,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final staleRequest = http.Request(
        'POST',
        Uri.parse(
            'https://backend.invalid/auth/v1/token?grant_type=refresh_token'));
    staleRequest.body = jsonEncode({'refresh_token': 'synthetic-secret'});
    await expectLater(
        transport.send(staleRequest), throwsA(isA<http.ClientException>()));
    expect(db.owner!['state'], 'active');
    response.complete(http.StreamedResponse(const Stream.empty(), 401));
    final error = await rejected;
    expect(error, isA<http.ClientException>());
    expect(error.toString(), isNot(contains('synthetic-secret')));
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.found);
    transport.close();
    store.dispose();
    scope.dispose();
    await events.close();
  });

  test('refresh denial commits revoke; socket and timeout stay pending',
      () async {
    for (final scenario in ['denied', 'socket', 'timeout']) {
      final events = StreamController<AuthState>.broadcast(sync: true);
      final session = fakeSession('a');
      final scope = AuthSessionScope(
          currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      final now = DateTime.utc(2026, 11, 6);
      final binding = OfflineSessionBinding(
          issuer: 'https://backend.invalid/auth/v1',
          userId: 'a',
          sessionId: 'session-a',
          notBefore: now.subtract(const Duration(hours: 1)),
          expiresAt: now.add(const Duration(hours: 1)));
      final db = _Database();
      final store = SqlitePolicyGrantStore(
          scope: scope,
          currentBinding: () => binding,
          coordinator: SqlitePolicyGrantCoordinator(db),
          clock: () => now);
      final old = (await store.beginLiveCheck(scope.capture()!, binding))!;
      expect(
          await store.saveAllowed(
              old,
              OfflinePolicyGrant(
                  issuer: binding.issuer,
                  userId: binding.userId,
                  sessionId: binding.sessionId,
                  checkedAt: now,
                  validUntil: now.add(const Duration(hours: 1)))),
          isTrue);
      final transport = CoordinatedRefreshClient.forTesting(
          _HttpClient((request) async {
        expect(db.owner!['state'], 'revoked');
        if (scenario == 'socket') throw const SocketException('offline');
        if (scenario == 'timeout') throw TimeoutException('timeout');
        return http.StreamedResponse(const Stream.empty(), 401);
      }), store, Uri.parse('https://backend.invalid'),
          currentRefreshToken: () => session.refreshToken);
      final request = http.Request(
          'POST',
          Uri.parse(
              'https://backend.invalid/auth/v1/token?grant_type=refresh_token'));
      request.body = jsonEncode({'refresh_token': 'refresh'});
      if (scenario == 'denied') {
        expect((await transport.send(request)).statusCode, 401);
        expect(db.owner!['epoch'], 1);
        expect(db.grants, isEmpty);
      } else {
        await expectLater(transport.send(request), throwsA(anything));
      }
      expect((await store.readCandidate(scope.capture()!, binding)).status,
          SqliteGrantReadStatus.blocked);
      transport.close();
      store.dispose();
      scope.dispose();
      await events.close();
    }
  });

  test('local snapshot may outlive token but not a known revoke', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    var now = DateTime.utc(2026, 11, 6);
    var binding = OfflineSessionBinding(
        issuer: 'https://backend.invalid/auth/v1',
        userId: 'a',
        sessionId: 'session-a',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    final db = _Database();
    SqlitePolicyGrantStore makeStore() => SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    var store = makeStore();
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    final grant = OfflinePolicyGrant(
        issuer: binding.issuer,
        userId: binding.userId,
        sessionId: binding.sessionId,
        checkedAt: now,
        validUntil: now.add(const Duration(days: 30)));
    expect(await store.saveAllowed(attempt, grant), isTrue);
    now = now.add(const Duration(hours: 2));
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    session = fakeSession('a', access: 'refreshed-token');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    binding = OfflineSessionBinding(
        issuer: binding.issuer,
        userId: binding.userId,
        sessionId: binding.sessionId,
        notBefore: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    final proof = db.grants['session-a']!['token_nbf'];
    db.grants['session-a']!['token_nbf'] = null;
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
    db.grants['session-a']!['token_nbf'] = proof;
    await store.beginRevoke(binding);
    store.dispose();
    store = makeStore();
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
    store.dispose();
    scope.dispose();
    await events.close();
  });

  test('expired SDK session: offline is distinct from confirmed denial',
      () async {
    final clockNow = DateTime.now().toUtc();
    final checkedAt = clockNow.subtract(const Duration(minutes: 2));
    final expiry = clockNow.subtract(const Duration(minutes: 1));
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final access = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://backend.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat': checkedAt
                  .subtract(const Duration(minutes: 5))
                  .millisecondsSinceEpoch ~/
              1000,
          'exp': expiry.millisecondsSinceEpoch ~/ 1000,
        })}.sig';
    final client = SupabaseClient('https://backend.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    await client.auth.setInitialSession(jsonEncode({
      'access_token': access,
      'refresh_token': 'test-refresh',
      'token_type': 'bearer',
      'expires_at': expiry.millisecondsSinceEpoch ~/ 1000,
      'expires_in': 3600,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      },
    }));
    expect(client.auth.currentSession!.isExpired, isTrue);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: events.stream);
    events.add(
        AuthState(AuthChangeEvent.initialSession, client.auth.currentSession));
    final binding = OfflineSessionBinding.fromSession(
        client.auth.currentSession!, 'https://backend.invalid/auth/v1')!;
    final db = _Database();
    var clock = checkedAt;
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => clock);
    final attempt = (await store.beginLiveCheck(scope.capture()!, binding))!;
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: binding.issuer,
                userId: binding.userId,
                sessionId: binding.sessionId,
                checkedAt: checkedAt,
                validUntil: checkedAt.add(const Duration(days: 30)))),
        isTrue);
    clock = clockNow;
    expect(
        await AuthSession.restoreSessionStatus(client,
            refresh: () async => throw const SocketException('offline')),
        SessionRestoreStatus.transportFailure);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.found);
    expect(
        await AuthSession.restoreSessionStatus(client,
            refresh: () async =>
                throw const AuthApiException('revoked', statusCode: '401')),
        SessionRestoreStatus.rejected);
    // Runtime wiring is deliberately absent; model the required durable revoke.
    await store.beginRevoke(binding);
    expect((await store.readCandidate(scope.capture()!, binding)).status,
        SqliteGrantReadStatus.blocked);
    store.dispose();
    scope.dispose();
    await events.close();
    await client.dispose();
  });

  test('actual SDK denial is fenced before it clears the session', () async {
    final now = DateTime.now().toUtc();
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final access = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://backend.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
                  1000,
        })}.sig';
    var sent = false;
    final inner = _HttpClient((request) async {
      sent = true;
      return http.StreamedResponse(
          Stream.value(utf8.encode(
              '{"msg":"revoked","error_code":"refresh_token_not_found"}')),
          401,
          headers: {'content-type': 'application/json'});
    });
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://backend.invalid'));
    final sdk = SupabaseClient('https://backend.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await sdk.auth.setInitialSession(jsonEncode({
      'access_token': access,
      'refresh_token': 'test-refresh',
      'token_type': 'bearer',
      'expires_at':
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
              1000,
      'expires_in': 3600,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      },
    }));
    final pending = AuthSession.restoreSessionStatus(sdk);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(sent, isFalse);
    final scope = AuthSessionScope(
        currentSession: () => sdk.auth.currentSession,
        authEvents: sdk.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => sdk.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            sdk.auth.currentSession!, 'https://backend.invalid/auth/v1');
    final db = _Database();
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final b = binding()!;
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: now.subtract(const Duration(minutes: 2)),
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://backend.invalid'),
        currentRefreshToken: () => sdk.auth.currentSession?.refreshToken));
    final result = await pending;
    expect(sent, isTrue);
    expect(result, SessionRestoreStatus.stale);
    expect(sdk.auth.currentSession, isNull);
    expect(db.grants, isEmpty);
    store.dispose();
    scope.dispose();
    await sdk.dispose();
  });
}
