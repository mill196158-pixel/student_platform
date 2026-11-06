import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/refresh_policy_grant_observer.dart';
import 'package:student_platform/src/core/refresh_security_fence.dart';
import 'package:student_platform/src/core/qa_online_side_effect_coordinator.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Storage extends LocalStorage {
  _Storage(this.raw);
  String? raw;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => raw != null;
  @override
  Future<String?> accessToken() async => raw;
  @override
  Future<void> persistSession(String value) async {
    raw = value;
  }

  @override
  Future<void> removePersistedSession() async {
    raw = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('process gate refuses to settle overlapping refresh starts', () async {
    final release = Completer<void>();
    final inner = MockClient((request) async {
      await release.future;
      return http.Response('{}', 200, request: request);
    });
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), trackQaRefresh: true);
    gate.bind(inner);
    final uri = Uri.parse('https://a.invalid/auth/v1/token?grant_type=refresh_token');
    final first = gate.send(http.Request('POST', uri));
    final second = gate.send(http.Request('POST', uri));
    await Future<void>.delayed(Duration.zero);
    expect(gate.refreshStarts.value, 2);
    expect(gate.qaRefreshPending, isTrue);
    expect(gate.confirmQaRefresh(), isFalse);
    release.complete();
    await Future.wait([first, second]);
    expect(gate.confirmQaRefresh(), isFalse);
    gate.close();
  });
  for (final scenario in [
    'allowed',
    'unchanged',
    'unchanged_twice',
    'unchanged_block',
    'denied',
    'password',
    'unavailable',
    'malformed',
    'stale',
    'explicit',
    'between',
    'late401',
    'drain'
    ,'resume', 'resume_drain', 'resume_block_drain', 'resume_fail'
  ]) {
    test('SDK refresh and $scenario policy survive SQLite reopen safely',
        () async {
      if (Platform.isWindows)
        open.overrideFor(OperatingSystem.windows,
            () => DynamicLibrary.open('winsqlite3.dll'));
      sqfliteFfiInit();
      SharedPreferences.setMockInitialValues({});
      final dir = await Directory.systemTemp.createTemp('refresh_policy_qa_');
      final path = '${dir.path}/policy.db';
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      String part(Object v) =>
          base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
      Map<String, dynamic> response(int version, {String uid = 'a'}) {
        final token = '${part({'alg': 'HS256'})}.${part({
              'iss': 'https://a.invalid/auth/v1',
              'sub': uid,
              'session_id': uid == 'a'
                  ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
                  : 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              'aud': 'authenticated',
              'role': 'authenticated',
              'iat': now - 10 + version,
              'exp': now + 3600 + version
            })}.sig$version';
        return {
          'access_token': token,
          'refresh_token': 'refresh-$version',
          'token_type': 'bearer',
          'expires_in': 3600,
          'expires_at': now + 3600 + version,
          'user': {
            'id': uid,
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
            'created_at': '2026-01-01T00:00:00Z'
          }
        };
      }

      var policyCalls = 0, refreshCalls = 0, refreshStarts = 0;
      final entered = Completer<void>(), release = Completer<void>();
      final inner = MockClient((request) async {
        if (request.url.path == '/auth/v1/token') {
          if (request.url.queryParameters['grant_type'] != 'password') {
            expect(refreshStarts, greaterThan(refreshCalls));
            refreshCalls++;
          }
          return http.Response(
              jsonEncode(request.url.queryParameters['grant_type'] == 'password'
                  ? response(3, uid: 'b')
                  : response(scenario == 'unchanged' ||
                          scenario == 'unchanged_block' ||
                          (scenario == 'unchanged_twice' && refreshCalls == 1)
                      ? 1
                      : 2)),
              200,
              headers: {'content-type': 'application/json'},
              request: request);
        }
        if (request.url.path == '/rest/v1/users') {
          policyCalls++;
          if (scenario == 'stale' ||
              scenario == 'explicit' ||
              scenario == 'unchanged_block' ||
              scenario == 'late401' ||
              scenario == 'drain') {
            entered.complete();
            await release.future;
          }
          if (scenario == 'unavailable') throw const SocketException('offline');
          if (scenario == 'denied')
            return http.Response('{}', 403, request: request);
          if (scenario == 'late401')
            return http.Response('{}', 401, request: request);
          if (scenario == 'malformed')
            return http.Response('[{"id":"a"}]', 200,
                headers: {'content-type': 'application/json'},
                request: request);
          if (scenario == 'password')
            return http.Response(
                '[{"id":"a","must_change_password":true}]', 200,
                headers: {'content-type': 'application/json'},
                request: request);
          return http.Response('[{"id":"a","must_change_password":false}]', 200,
              headers: {'content-type': 'application/json'}, request: request);
        }
        return http.Response('{}', 404, request: request);
      });
      final fence = RefreshSecurityFence();
      final gate = RefreshAdmissionClient(inner,
          backend: Uri.parse('https://a.invalid'), securityFence: fence,
          trackQaRefresh: true);
      gate.refreshStarts.addListener(() => refreshStarts++);
      await Supabase.initialize(
          url: 'https://a.invalid',
          publishableKey: 'qa',
          httpClient: gate,
          authOptions: FlutterAuthClientOptions(
              autoRefreshToken: false,
              detectSessionInUri: false,
              localStorage: _Storage(jsonEncode(response(1)))));
      final client = Supabase.instance.client;
      final scope = AuthSessionScope(
          currentSession: () => client.auth.currentSession,
          authEvents: client.auth.onAuthStateChange);
      await scope.ready;
      OfflineSessionBinding? binding() => client.auth.currentSession == null
          ? null
          : OfflineSessionBinding.fromSession(
              client.auth.currentSession!, 'https://a.invalid/auth/v1');
      var db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
      var store = SqlitePolicyGrantStore(
          scope: scope,
          currentBinding: binding,
          coordinator: SqlitePolicyGrantCoordinator(db));
      gate.bind(CoordinatedRefreshClient.forTesting(
          inner, store, Uri.parse('https://a.invalid'),
          currentRefreshToken: () => client.auth.currentSession?.refreshToken,
          securityFence: fence));
      final caps = SessionCapabilities(scope),
          owner = scope.capture()!,
          initial = binding()!;
      final first = (await store.beginLiveCheck(owner, initial))!;
      final checked = DateTime.now().toUtc();
      expect(
          await store.saveAllowed(
              first,
              OfflinePolicyGrant(
                  issuer: initial.issuer,
                  userId: initial.userId,
                  sessionId: initial.sessionId,
                  checkedAt: checked,
                  validUntil: checked.add(const Duration(hours: 1)))),
          true);
      expect(
          caps.grant(
              SessionCapabilityMode.online, caps.beginAuthorization(owner)!),
          true);
      final interleaved = client.auth.onAuthStateChange.listen((event) {
        if (scenario == 'between' &&
            event.event == AuthChangeEvent.tokenRefreshed) caps.block();
      });
      final onlineCoordinator = QaOnlineSideEffectCoordinator();
      final oldWorkStarted = Completer<void>();
      final oldWorkRelease = Completer<void>();
      final reentryStarted = Completer<void>();
      if (scenario == 'resume_drain' || scenario == 'resume_block_drain') {
        final old = onlineCoordinator.open(() => true)!;
        unawaited(old.run(() async {
          oldWorkStarted.complete();
          await oldWorkRelease.future;
        }));
        await oldWorkStarted.future;
      }
      var rotationReceipts = 0;
      final observer = RefreshPolicyGrantObserver.forTesting(
          client: client,
          scope: scope,
          store: store,
          gate: gate,
          fence: fence,
          policy: SettledPolicyTransport.forTesting(
              inner, Uri.parse('https://a.invalid')),
          backend: Uri.parse('https://a.invalid'),
          publicKey: 'qa',
          onVerifiedRotation: (previous, current, actualCaps) {
            expect(previous, owner);
            expect(scope.isCurrent(previous), previous == current);
            expect(scope.isCurrent(current), isTrue);
            expect(identical(actualCaps, caps), isTrue);
            rotationReceipts++;
          },
          closePreviousOnline: scenario.startsWith('resume') ? () async {
            reentryStarted.complete();
            if (scenario == 'resume_fail') return false;
            return onlineCoordinator.closeAndWait(timeout: const Duration(seconds: 5));
          } : null);
      expect(observer.arm(owner, initial, caps), true);
      await client.auth.refreshSession();
      if (scenario == 'resume_drain' || scenario == 'resume_block_drain') {
        await reentryStarted.future;
        expect(caps.mode, SessionCapabilityMode.blocked);
        if (scenario == 'resume_block_drain') caps.block();
        oldWorkRelease.complete();
      }
      if (scenario == 'stale' ||
          scenario == 'explicit' ||
          scenario == 'unchanged_block' ||
          scenario == 'late401' ||
          scenario == 'drain') {
        await entered.future;
        if (scenario == 'stale') scope.invalidateForSignOut();
        if (scenario == 'explicit' || scenario == 'unchanged_block')
          caps.block();
        if (scenario == 'late401') {
          await client.auth.signInWithPassword(
              email: 'synthetic@example.invalid', password: 'synthetic');
          await Future<void>.delayed(Duration.zero);
          final bOwner = scope.capture()!, bBinding = binding()!;
          final bAttempt = (await store.beginLiveCheck(bOwner, bBinding))!;
          final bNow = DateTime.now().toUtc();
          expect(
              await store.saveAllowed(
                  bAttempt,
                  OfflinePolicyGrant(
                      issuer: bBinding.issuer,
                      userId: bBinding.userId,
                      sessionId: bBinding.sessionId,
                      checkedAt: bNow,
                      validUntil: bNow.add(const Duration(hours: 1)))),
              true);
        }
        if (scenario == 'drain') {
          var drained = false;
          final waiting = gate.suspendAndDrain().then((_) => drained = true);
          await Future<void>.delayed(Duration.zero);
          expect(drained, false);
          release.complete();
          await waiting;
          expect(drained, true);
        } else {
          release.complete();
        }
      }
      await Future<void>.delayed(Duration.zero);
      await observer.settled();
      if (scenario.startsWith('resume')) {
        expect(caps.mode,
            scenario == 'resume' || scenario == 'resume_drain'
                ? SessionCapabilityMode.online : SessionCapabilityMode.blocked);
        expect(rotationReceipts,
            scenario == 'resume' || scenario == 'resume_drain' ? 1 : 0);
      } else {
        expect(rotationReceipts,
            scenario == 'unchanged' || scenario == 'unchanged_twice' ? 1 : 0);
      }
      if (scenario == 'unchanged_twice') {
        await client.auth.refreshSession();
        await Future<void>.delayed(Duration.zero);
        await observer.settled();
      }
      expect(policyCalls,
          scenario == 'between' ? 0 : (scenario == 'unchanged_twice' ? 2 : 1));
      if (scenario == 'stale') {
        final rows = await db.rawQuery('SELECT state FROM policy_owner');
        expect(rows.single['state'], 'revoked');
        await observer.dispose();
        await interleaved.cancel();
        caps.dispose();
        store.dispose();
        scope.dispose();
        await Supabase.instance.dispose();
        await db.close();
        await databaseFactoryFfi.deleteDatabase(path);
        await dir.delete();
        return;
      }
      expect(
          (await store.readCandidate(scope.capture()!, binding()!)).status ==
              SqliteGrantReadStatus.found,
          scenario == 'allowed' ||
              scenario == 'unchanged' ||
              scenario == 'unchanged_twice' ||
              scenario == 'drain' ||
              scenario == 'late401' || scenario.startsWith('resume'));
      await observer.dispose();
      await interleaved.cancel();
      store.dispose();
      await db.close();
      db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
      store = SqlitePolicyGrantStore(
          scope: scope,
          currentBinding: binding,
          coordinator: SqlitePolicyGrantCoordinator(db));
      expect(
          (await store.readCandidate(scope.capture()!, binding()!)).status ==
              SqliteGrantReadStatus.found,
          scenario == 'allowed' ||
              scenario == 'unchanged' ||
              scenario == 'unchanged_twice' ||
              scenario == 'drain' ||
              scenario == 'late401' || scenario.startsWith('resume'));
      caps.dispose();
      store.dispose();
      scope.dispose();
      await Supabase.instance.dispose();
      await db.close();
      await databaseFactoryFfi.deleteDatabase(path);
      await dir.delete();
    });
  }
}
