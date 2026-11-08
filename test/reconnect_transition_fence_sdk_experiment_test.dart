import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/reconnect_transition_fence_experiment.dart';
import 'package:student_platform/src/core/serial_auth_local_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _CountingStorage extends LocalStorage {
  int calls = 0;
  @override Future<void> initialize() async { calls++; }
  @override Future<bool> hasAccessToken() async { calls++; return false; }
  @override Future<String?> accessToken() async { calls++; return null; }
  @override Future<void> persistSession(String value) async { calls++; }
  @override Future<void> removePersistedSession() async { calls++; }
}

Map<String, dynamic> _session(int version) {
  String part(Object v) => base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  const user = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  return {'access_token': '${part({'alg':'none'})}.${part({'sub':user,
    'session_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'iat':now,
    'exp':now+3600, 'version':version})}.sig', 'refresh_token':'synthetic-$version',
    'token_type':'bearer', 'expires_in':3600, 'expires_at':now+3600,
    'user':{'id':user, 'aud':'authenticated', 'app_metadata':{},
      'user_metadata':{}, 'created_at':'2026-01-01T00:00:00Z'}};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('real SDK refresh dispatch invalidates an already claimed intent', () async {
    SharedPreferences.setMockInitialValues({});
    final inner = MockClient((request) async {
      expect(request.url.path, '/auth/v1/token');
      return http.Response(jsonEncode(_session(2)), 200,
          request: request, headers: {'content-type':'application/json'});
    });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    gate.bind(inner);
    final counter = _CountingStorage();
    final storage = SerialAuthLocalStorage(counter);
    await Supabase.initialize(url:'https://example.invalid', publishableKey:'test',
      httpClient:gate, authOptions:FlutterAuthClientOptions(autoRefreshToken:false, localStorage:storage));
    final client = Supabase.instance.client;
    await client.auth.setInitialSession(jsonEncode(_session(1)));
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
      authEvents:client.auth.onAuthStateChange);
    await scope.ready;
    final fence = ReconnectTransitionFenceExperiment.syntheticManaged(
      scope:scope, authSignals:gate.authSignals,
      isQuiescent: () => gate.activeAuthOperations == 0);
    final ticket = fence.capture()!;
    expect(fence.permits(ticket), isTrue);
    await client.auth.refreshSession();
    expect(fence.permits(ticket), isFalse);
    expect(fence.capture(), isNull);
    fence.dispose();
    await Future<void>.delayed(Duration.zero);
    final original = scope.capture();
    expect(original, isNotNull);
    final originalJson = jsonEncode(client.auth.currentSession!.toJson());
    final signalBefore = gate.authSignals.value;
    final authEventBefore = scope.authSignalRevision;
    await storage.drain();
    final storageBefore = counter.calls;
    final unknown = ReconnectTransitionFenceExperiment(scope:scope, authSignals:gate.authSignals);
    // The locked SDK's recoverSession silently replaces an unexpired session
    // when the user ID is unchanged. A -> B -> A therefore emits no signal.
    await client.auth.recoverSession(jsonEncode(_session(1)));
    await client.auth.recoverSession(originalJson);
    await Future<void>.delayed(Duration.zero);
    await storage.drain();
    expect(counter.calls, storageBefore);
    expect(gate.authSignals.value, signalBefore);
    expect(scope.authSignalRevision, authEventBefore);
    expect(scope.isCurrent(original!), isTrue);
    expect(unknown.capture(), isNull);
    unknown.dispose(); scope.dispose(); await Supabase.instance.dispose();
  });
}
