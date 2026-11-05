import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/live_policy_grant_bridge.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_policy_grant_store.dart';
import 'package:student_platform/src/core/password_policy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;
import 'cold_start_session_test.dart' show sessionFixture;
import 'offline_policy_grant_store_test.dart' show MemoryStorage;

void main() {
  final now = DateTime.utc(2026, 11, 5, 12);
  final binding = OfflineSessionBinding(
      issuer: 'issuer',
      userId: 'a',
      sessionId: 'sid',
      notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
  late StreamController<AuthState> events;
  late Session current;
  late AuthSessionScope scope;
  late MemoryStorage storage;
  late OfflinePolicyGrantStore store;
  setUp(() {
    events = StreamController<AuthState>.broadcast(sync: true);
    current = fakeSession('a');
    scope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    storage = MemoryStorage();
    store = OfflinePolicyGrantStore(
        session: scope, currentBinding: () => binding, storage: storage);
  });
  tearDown(() async {
    store.dispose();
    scope.dispose();
    await events.close();
  });

  LivePolicyGrantBridge bridge(Future<bool> Function() live) =>
      LivePolicyGrantBridge(
          scope: scope,
          store: store,
          currentBinding: () => binding,
          readLivePolicy: live,
          clock: () => now);

  test('successful live check returns without waiting for disk', () async {
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    expect(await bridge(() async => false).check(), isFalse);
    await storage.writeEntered!.future;
    expect(storage.values, isEmpty);
    storage.writeRelease!.complete();
    expect(await store.read(scope.capture()!, binding), isNotNull);
  });
  test('storage failure does not change successful online decision', () async {
    storage.failWrite = true;
    expect(await bridge(() async => false).check(), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(await store.read(scope.capture()!, binding), isNull);
  });
  test('missing local binding does not change a valid online decision',
      () async {
    final instance = LivePolicyGrantBridge(
        scope: scope,
        store: store,
        currentBinding: () => null,
        readLivePolicy: () async => false,
        clock: () => now);
    expect(await instance.check(), isFalse);
    expect(storage.values, isEmpty);
  });
  test('transport failure does not mint or extend a saved grant', () async {
    final owner = scope.capture()!;
    final seed = store.beginLiveCheck(owner, binding)!;
    final grant = OfflinePolicyGrant(
        issuer: binding.issuer,
        userId: 'a',
        sessionId: 'sid',
        checkedAt: now.subtract(const Duration(hours: 1)),
        validUntil: now.add(const Duration(minutes: 5)));
    expect(await store.saveAfterLiveCheck(seed, grant), isTrue);
    await expectLater(
        bridge(() async => throw TimeoutException('offline')).check(),
        throwsA(isA<TimeoutException>()));
    expect((await store.read(owner, binding))?.validUntil, grant.validUntil);
  });
  test('old result after account change is stale for allow, change, and denial',
      () async {
    for (final outcome in ['allow', 'change', 'denial']) {
      current = fakeSession('a', access: 'new-$outcome');
      events.add(AuthState(AuthChangeEvent.signedIn, current));
      final pending = Completer<bool>();
      final result = bridge(() => pending.future).check();
      current = fakeSession('b', access: 'b-$outcome');
      events.add(AuthState(AuthChangeEvent.signedIn, current));
      if (outcome == 'denial') {
        pending
            .completeError(const AuthApiException('denied', statusCode: '401'));
      } else {
        pending.complete(outcome == 'change');
      }
      await expectLater(result, throwsA(isA<PolicyCheckStale>()));
      expect(storage.values, isEmpty);
    }
  });
  test('later live check wins over an earlier delayed response', () async {
    final old = Completer<bool>();
    var calls = 0;
    final instance =
        bridge(() => ++calls == 1 ? old.future : Future.value(true));
    final earlier = instance.check();
    expect(await instance.check(), isTrue);
    old.complete(false);
    await expectLater(earlier, throwsA(isA<PolicyCheckStale>()));
    expect(await store.read(scope.capture()!, binding), isNull);
  });
  test('real Postgrest 401/403 codes revoke the stored grant', () async {
    var code = '42501';
    final client = SupabaseClient('https://example.test', 'public-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response(
            jsonEncode({'code': code, 'message': 'denied'}),
            code == 'PGRST302' || code == 'PT401' ? 401 : 403,
            request: request,
            headers: {'content-type': 'application/json'})));
    addTearDown(client.dispose);
    final expiry = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    final fixture = sessionFixture(expiry);
    (fixture['user'] as Map<String, dynamic>)['id'] = 'a';
    await client.auth.setInitialSession(jsonEncode(fixture));
    final grant = OfflinePolicyGrant(
        issuer: binding.issuer,
        userId: 'a',
        sessionId: 'sid',
        checkedAt: now,
        validUntil: now.add(const Duration(hours: 1)));
    for (code in ['42501', 'PGRST302', 'PT401', 'PT403']) {
      final seed = store.beginLiveCheck(scope.capture()!, binding)!;
      expect(await store.saveAfterLiveCheck(seed, grant), isTrue);
      await expectLater(
          bridge(() => loadPasswordChangeRequired(client)).check(),
          throwsA(isA<PostgrestException>()));
      expect(await store.read(scope.capture()!, binding), isNull);
      await store.blockAndRevoke(binding);
    }
  });
}
