import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_startup_admission.dart';
import 'package:student_platform/src/core/refresh_security_fence.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemoryAuthStorage extends LocalStorage {
  _MemoryAuthStorage(this.raw);
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
  test(
      'Supabase Flutter persisted expired session passes held gate and local proof',
      () async {
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('flutter_bootstrap_'),
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
    final raw = jsonEncode({
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
    });
    final saved = Session.fromJson(jsonDecode(raw))!;
    final initialEvents = StreamController<AuthState>.broadcast(sync: true);
    final priorScope = AuthSessionScope(
        currentSession: () => saved, authEvents: initialEvents.stream);
    initialEvents.add(AuthState(AuthChangeEvent.initialSession, saved));
    final binding =
        OfflineSessionBinding.fromSession(saved, 'https://a.invalid/auth/v1')!;
    var db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    var store = SqlitePolicyGrantStore(
        scope: priorScope,
        currentBinding: () => binding,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final attempt =
        (await store.beginLiveCheck(priorScope.capture()!, binding))!;
    expect(
        await store.saveAllowed(
            attempt,
            OfflinePolicyGrant(
                issuer: binding.issuer,
                userId: binding.userId,
                sessionId: binding.sessionId,
                checkedAt: now.subtract(const Duration(minutes: 2)),
                validUntil: now.add(const Duration(hours: 1)))),
        isTrue);
    store.dispose();
    priorScope.dispose();
    await initialEvents.close();
    await db.close();
    final memory = _MemoryAuthStorage(raw);
    var calls = 0;
    final inner = MockClient((_) async {
      calls++;
      throw const SocketException('offline');
    });
    final fence = RefreshSecurityFence(), monitor = RefreshTransportMonitor();
    final gate = RefreshAdmissionClient(inner,
        backend: Uri.parse('https://a.invalid'), securityFence: fence);
    await Supabase.initialize(
        url: 'https://a.invalid',
        anonKey: 'test',
        httpClient: gate,
        authOptions: FlutterAuthClientOptions(
            autoRefreshToken: true,
            localStorage: memory,
            detectSessionInUri: false));
    final client = Supabase.instance.client;
    final scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    expect(client.auth.currentSession?.isExpired, isTrue);
    expect(calls, 0);
    OfflineSessionBinding? current() => client.auth.currentSession == null
        ? null
        : OfflineSessionBinding.fromSession(
            client.auth.currentSession!, 'https://a.invalid/auth/v1');
    db = await openPolicyGrantDatabase(path, factory: databaseFactoryFfi);
    store = SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: current,
        coordinator: SqlitePolicyGrantCoordinator(db));
    final owner = scope.capture()!,
        prior = await store.capturePriorGrant(owner, current()!),
        rev = fence.revision;
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
        binding: binding,
        prior: prior,
        fenceRevision: rev);
    final caps = SessionCapabilities(scope);
    expect(await admission.resolve(caps), OfflineStartupResult.cacheOnly);
    expect(caps.capture(SessionCapability.cachedRead), isNotNull);
    expect(memory.raw, isNotNull);
    caps.dispose();
    store.dispose();
    scope.dispose();
    await Supabase.instance.dispose();
    await db.close();
    await databaseFactoryFfi.deleteDatabase(path);
    await dir.delete();
  }, timeout: const Timeout(Duration(seconds: 55)));
}
