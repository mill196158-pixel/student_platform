import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/core/auth_session.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/local_snapshot_startup.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _sessionJson({required bool expired}) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final exp = now + (expired ? -30 : 3600);
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final token = '${part({'alg': 'HS256'})}.${part({
    'iss': 'https://example.invalid/auth/v1', 'sub': 'owner',
    'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'role': 'authenticated', 'aud': 'authenticated', 'iat': now - 120, 'exp': exp,
  })}.sig';
  return jsonEncode({'access_token': token, 'refresh_token': 'test-refresh',
    'token_type': 'bearer', 'expires_in': 3600, 'expires_at': exp,
    'user': {'id': 'owner', 'aud': 'authenticated', 'app_metadata': {},
      'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('denial drops held refresh but permits a later session refresh', () async {
    var sends = 0;
    final inner = MockClient((_) async { sends++; return http.Response('{}', 200); });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    http.Request request() => http.Request('POST', Uri.parse(
        'https://example.invalid/auth/v1/token?grant_type=refresh_token'));
    final held = gate.send(request());
    gate.discardHeldRefreshes();
    gate.bind(inner);
    await expectLater(held, throwsA(isA<RefreshTransportSuppressed>()));
    expect(sends, 0);
    expect((await gate.send(request())).statusCode, 200);
    expect(sends, 1);
    gate.close();
  });
  test('expired saved SDK session shows local data without dispatching held refresh', () async {
    var sends = 0;
    final inner = MockClient((_) async { sends++; throw StateError('unexpected request'); });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    final client = SupabaseClient('https://example.invalid', 'test', httpClient: gate,
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    await client.auth.setInitialSession(_sessionJson(expired: true));
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    final caps = SessionCapabilities(scope);
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1', wait: const Duration(milliseconds: 30),
        restore: () => AuthSession.restoreSessionStatus(client),
        checkPolicy: () async => throw StateError('expired session must refresh first'),
        onCacheOnly: gate.suspendAndDrain);
    expect(await startup.resolve(caps), OfflineStartupResult.cacheOnly);
    expect(sends, 0);
    expect(caps.capture(SessionCapability.cachedRead), isNotNull);
    expect(caps.capture(SessionCapability.mutation), isNull);
    gate.bind(inner);
    await Future<void>.delayed(Duration.zero);
    caps.dispose(); scope.dispose(); await client.dispose();
  });

  test('expired SDK session refreshes immediately when startup detects network', () async {
    var sends = 0;
    final inner = MockClient((request) async {
      sends++;
      return http.Response(_sessionJson(expired: false), 200,
          headers: {'content-type': 'application/json'});
    });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    final client = SupabaseClient('https://example.invalid', 'test', httpClient: gate,
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    await client.auth.setInitialSession(_sessionJson(expired: true));
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    final caps = SessionCapabilities(scope);
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1', wait: const Duration(seconds: 2),
        restore: () {
          if (sends == 0) scheduleMicrotask(() => gate.bind(inner));
          return AuthSession.restoreSessionStatus(client);
        },
        checkPolicy: () async => SettledPolicyStatus.allowed);
    expect(await startup.resolve(caps), OfflineStartupResult.online);
    expect(sends, greaterThan(0));
    expect(caps.capture(SessionCapability.mutation), isNotNull);
    caps.dispose(); scope.dispose(); await client.dispose();
  });

  test('held refresh can resume and re-check policy after offline startup', () async {
    var sends = 0;
    var policyChecks = 0;
    final inner = MockClient((_) async {
      sends++;
      return http.Response(_sessionJson(expired: false), 200,
          headers: {'content-type': 'application/json'});
    });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    final client = SupabaseClient('https://example.invalid', 'test', httpClient: gate,
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    await client.auth.setInitialSession(_sessionJson(expired: true));
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    final caps = SessionCapabilities(scope);
    final startup = LocalSnapshotStartup(scope: scope,
        issuer: 'https://example.invalid/auth/v1', wait: const Duration(milliseconds: 40),
        restore: () => AuthSession.restoreSessionStatus(client),
        checkPolicy: () async { policyChecks++; return SettledPolicyStatus.allowed; },
        onCacheOnly: gate.suspendAndDrain);
    expect(await startup.resolve(caps), OfflineStartupResult.cacheOnly);
    expect(sends, 0);
    gate.resume();
    gate.bind(inner);
    expect(await startup.resolve(caps), OfflineStartupResult.online);
    expect(sends, greaterThan(0));
    expect(policyChecks, 1);
    expect(caps.capture(SessionCapability.mutation), isNotNull);
    caps.dispose(); scope.dispose(); await client.dispose();
  });
}
