import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/refresh_security_fence.dart';
import 'package:student_platform/src/core/settled_policy_transport.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:student_platform/src/core/offline_auth_error_receipt.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FaultGate extends RefreshAdmissionClient {
  _FaultGate(http.Client inner,
      {required Uri backend,
      required RefreshSecurityFence fence,
      required this.beforeDrain})
      : super(inner, backend: backend, securityFence: fence);
  final Future<void> Function() beforeDrain;
  @override
  Future<void> suspendAndDrain() async {
    final drained = super.suspendAndDrain();
    await beforeDrain();
    await drained;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('expired saved session plus settled socket failures grants cache-only',
      () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
                  1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      throw const SocketException('offline');
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
              1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision);
    final capabilities = SessionCapabilities(scope);
    expect(
        await admission.resolve(capabilities), OfflineStartupResult.cacheOnly);
    expect(requests, greaterThan(0));
    expect(capabilities.capture(SessionCapability.cachedRead), isNotNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect((await store.readCandidate(scope.capture()!, b)).status,
        SqliteGrantReadStatus.found);
    final receipt = OfflineAuthErrorReceipt.instance;
    final socketError = scope.lastAuthError;
    expect(socketError, isNotNull);
    expect(receipt.accepts(socketError!), isTrue);
    client.auth.notifyException(AuthException('later unknown failure'));
    await Future<void>.delayed(Duration.zero);
    expect(receipt.accepts(socketError), isFalse);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
  test(
      'valid saved session plus settled policy socket failure grants cache-only',
      () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      throw const SocketException('offline');
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision,
        policy: SettledPolicyTransport.forTesting(
            inner, Uri.parse('https://a.invalid')),
        backend: Uri.parse('https://a.invalid'),
        publicKey: 'test');
    final capabilities = SessionCapabilities(scope);
    expect(
        await admission.resolve(capabilities), OfflineStartupResult.cacheOnly);
    expect(requests, greaterThan(0));
    expect(capabilities.capture(SessionCapability.cachedRead), isNotNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect((await store.readCandidate(scope.capture()!, b)).status,
        SqliteGrantReadStatus.found);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
  test('policy deadline then socket failure remains indeterminate', () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      throw const SocketException('offline');
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision,
        policy: SettledPolicyTransport.forTesting(
            inner, Uri.parse('https://a.invalid')),
        backend: Uri.parse('https://a.invalid'),
        publicKey: 'test',
        policyTimeout: Duration.zero);
    final capabilities = SessionCapabilities(scope);
    expect(await admission.resolve(capabilities),
        OfflineStartupResult.unavailable);
    expect(requests, greaterThan(0));
    expect(capabilities.capture(SessionCapability.cachedRead), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect((await store.readCandidate(scope.capture()!, b)).status,
        SqliteGrantReadStatus.blocked);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
  test('foreign policy origin cannot grant local access', () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      throw const SocketException('offline');
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision,
        policy: SettledPolicyTransport.forTesting(
            inner, Uri.parse('https://a.invalid')),
        backend: Uri.parse('https://b.invalid'),
        publicKey: 'test');
    final capabilities = SessionCapabilities(scope);
    expect(await admission.resolve(capabilities),
        OfflineStartupResult.unavailable);
    expect(requests, 0);
    expect(capabilities.capture(SessionCapability.cachedRead), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect((await store.readCandidate(scope.capture()!, b)).status,
        SqliteGrantReadStatus.found);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
  test('malformed policy is indeterminate and cannot grant offline', () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      return http.Response('bad-json', 200);
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision,
        policy: SettledPolicyTransport.forTesting(
            inner, Uri.parse('https://a.invalid')),
        backend: Uri.parse('https://a.invalid'),
        publicKey: 'test');
    final capabilities = SessionCapabilities(scope);
    expect(await admission.resolve(capabilities),
        OfflineStartupResult.unavailable);
    expect(requests, greaterThan(0));
    expect(capabilities.capture(SessionCapability.cachedRead), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect((await store.readCandidate(scope.capture()!, b)).status,
        SqliteGrantReadStatus.blocked);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
  test('policy 401 durably denies without cached access', () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      return http.Response('{}', 401);
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision,
        policy: SettledPolicyTransport.forTesting(
            inner, Uri.parse('https://a.invalid')),
        backend: Uri.parse('https://a.invalid'),
        publicKey: 'test');
    final capabilities = SessionCapabilities(scope);
    expect(await admission.resolve(capabilities), OfflineStartupResult.denied);
    expect(requests, greaterThan(0));
    expect(capabilities.capture(SessionCapability.cachedRead), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect((await store.readCandidate(scope.capture()!, b)).status,
        SqliteGrantReadStatus.blocked);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
  test('policy 403 durably denies without cached access', () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      return http.Response('{}', 403);
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision,
        policy: SettledPolicyTransport.forTesting(
            inner, Uri.parse('https://a.invalid')),
        backend: Uri.parse('https://a.invalid'),
        publicKey: 'test');
    final capabilities = SessionCapabilities(scope);
    expect(await admission.resolve(capabilities), OfflineStartupResult.denied);
    expect(requests, greaterThan(0));
    expect(capabilities.capture(SessionCapability.cachedRead), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    expect((await store.readCandidate(scope.capture()!, b)).status,
        SqliteGrantReadStatus.blocked);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
  test('SQLite loss during settlement fails closed instead of throwing',
      () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('startup_policy_'),
        path = '${dir.path}/p.db';
    final now = DateTime.now().toUtc();
    String part(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
          'iss': 'https://a.invalid/auth/v1',
          'sub': 'a',
          'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          'role': 'authenticated',
          'aud': 'authenticated',
          'iat':
              now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
                  1000,
          'exp':
              now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
                  1000
        })}.sig';
    var requests = 0;
    final inner = MockClient((_) async {
      requests++;
      throw const SocketException('offline');
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    late Future<void> Function() closeDb;
    final gate = _FaultGate(inner,
        backend: Uri.parse('https://a.invalid'),
        fence: fence,
        beforeDrain: () => closeDb());
    final client = SupabaseClient('https://a.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'synthetic',
      'token_type': 'bearer',
      'expires_in': 3600,
      'expires_at':
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
              1000,
      'user': {
        'id': 'a',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z'
      }
    }));
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    OfflineSessionBinding? binding() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    final b = binding()!;
    final db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    closeDb = db.close;
    final store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt = (await store.beginLiveCheck(scope.capture()!, b))!;
    final checked = now.subtract(const Duration(minutes: 2));
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: b.issuer,
                userId: b.userId,
                sessionId: b.sessionId,
                checkedAt: checked,
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    final prior = await store.capturePriorGrant(scope.capture()!, b);
    final owner = scope.capture()!, revision = fence.revision;
    gate.bind(CoordinatedRefreshClient.forTesting(
        inner, store, Uri.parse('https://a.invalid'),
        currentRefreshToken: () => client.auth.currentSession?.refreshToken,
        securityFence: fence,
        monitor: monitor));
    final admission = OfflineStartupAdmission(
        client: client,
        scope: scope,
        store: store,
        gate: gate,
        monitor: monitor,
        fence: fence,
        owner: owner,
        binding: b,
        prior: prior,
        fenceRevision: revision);
    final capabilities = SessionCapabilities(scope);
    expect(await admission.resolve(capabilities),
        OfflineStartupResult.unavailable);
    expect(requests, greaterThan(0));
    expect(capabilities.capture(SessionCapability.cachedRead), isNull);
    expect(capabilities.capture(SessionCapability.mutation), isNull);
    capabilities.dispose();
    store.dispose();
    scope.dispose();
    await client.dispose();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
}
