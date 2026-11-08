import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _session(int version) {
  String part(Object v) => base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  return {'access_token':'${part({'alg':'none'})}.${part({'sub':uid,
    'session_id':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'iat':now, 'exp':now+3600,
    'version':version})}.sig', 'refresh_token':'synthetic-$version',
    'token_type':'bearer', 'expires_in':3600, 'expires_at':now+3600,
    'user':{'id':uid, 'aud':'authenticated', 'app_metadata':{}, 'user_metadata':{},
      'created_at':'2026-01-01T00:00:00Z'}};
}

/// Reproduces a request parked before the admission client, without SDK edits.
class _BeforeGate extends http.BaseClient {
  _BeforeGate(this.gate);
  final http.Client gate;
  final entered = Completer<void>(), release = Completer<void>();
  bool holdFirst = true;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (holdFirst && request.url.path.endsWith('/auth/v1/token')) {
      holdFirst = false;
      entered.complete();
      await release.future;
    }
    return gate.send(request);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('one event/result/current can belong to an already pending SDK refresh', () async {
    SharedPreferences.setMockInitialValues({});
    var sends = 0;
    final started = Completer<void>(), response = Completer<http.Response>();
    final inner = MockClient((request) {
      sends++;
      if (!started.isCompleted) started.complete();
      return response.future;
    });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    gate.bind(inner);
    final before = _BeforeGate(gate);
    await Supabase.initialize(url:'https://example.invalid', publishableKey:'test',
      httpClient:before, authOptions:const FlutterAuthClientOptions(autoRefreshToken:false));
    final client = Supabase.instance.client;
    await client.auth.setInitialSession(jsonEncode(_session(1)));
    await Future<void>.delayed(Duration.zero);
    final old = client.auth.currentSession!;
    final observed = Completer<Session>();
    var refreshEvents = 0;
    final sub = client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.tokenRefreshed && state.session != null) {
        refreshEvents++;
        if (!observed.isCompleted) observed.complete(state.session!);
      }
    }, onError: (Object _, StackTrace __) {});
    final first = client.auth.refreshSession();
    await before.entered.future.timeout(const Duration(seconds: 2));
    expect(gate.refreshEntrants, 0);
    expect(identical(old, client.auth.currentSession), isTrue);
    // This second caller joins the SDK's private single-flight before gate entry.
    final second = client.auth.refreshSession();
    expect(gate.refreshEntrants, 0);
    before.release.complete();
    await started.future.timeout(const Duration(seconds: 2));
    expect(gate.refreshEntrants, 1);
    response.complete(http.Response(jsonEncode(_session(2)), 200,
      headers: {'content-type':'application/json'}));
    final results = await Future.wait([first, second]).timeout(const Duration(seconds: 2));
    final event = await observed.future.timeout(const Duration(seconds: 2));
    expect(sends, 1);
    expect(gate.refreshEntryRevision, 1);
    expect(refreshEvents, 1);
    expect(identical(results[0].session, results[1].session), isTrue);
    expect(identical(event, results[1].session), isTrue);
    expect(identical(client.auth.currentSession, event), isTrue);
    await sub.cancel(); await Supabase.instance.dispose();
  });

  test('actual SDK retry backoff permits joining pending refresh with gate idle', () async {
    SharedPreferences.setMockInitialValues({});
    var sends = 0;
    final failed = Completer<void>();
    final inner = MockClient((request) async {
      sends++;
      if (sends == 1) {
        failed.complete();
        throw const SocketException('synthetic offline');
      }
      return http.Response(jsonEncode(_session(2)), 200, request: request,
        headers: {'content-type':'application/json'});
    });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    gate.bind(inner);
    await Supabase.initialize(url:'https://example.invalid', publishableKey:'test',
      httpClient:gate, authOptions:const FlutterAuthClientOptions(autoRefreshToken:false));
    final client = Supabase.instance.client;
    await client.auth.setInitialSession(jsonEncode(_session(1)));
    await Future<void>.delayed(Duration.zero);
    final old = client.auth.currentSession!;
    final event = Completer<Session>();
    var eventCount = 0;
    final sub = client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.tokenRefreshed && state.session != null) {
        eventCount++;
        if (!event.isCompleted) event.complete(state.session!);
      }
    }, onError: (Object _, StackTrace __) {});
    var firstDone = false;
    final first = client.auth.refreshSession().whenComplete(() => firstDone = true);
    await failed.future.timeout(const Duration(seconds: 2));
    for (var i = 0; i < 50 && gate.refreshEntrants != 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gate.refreshEntrants, 0);
    expect(gate.activeAuthOperations, 0);
    expect(firstDone, isFalse);
    expect(identical(client.auth.currentSession, old), isTrue);
    final revision = gate.refreshEntryRevision;
    final joined = client.auth.refreshSession();
    final results = await Future.wait([first, joined]).timeout(const Duration(seconds: 3));
    final emitted = await event.future.timeout(const Duration(seconds: 2));
    expect(sends, 2);
    expect(gate.refreshEntryRevision, revision + 1);
    expect(eventCount, 1);
    expect(identical(results[0].session, results[1].session), isTrue);
    expect(identical(results[1].session, emitted), isTrue);
    expect(identical(client.auth.currentSession, emitted), isTrue);
    await sub.cancel(); await Supabase.instance.dispose();
  });

  test('stale refresh response is returned but never installed after silent ABA', () async {
    SharedPreferences.setMockInitialValues({});
    final started = Completer<void>(), response = Completer<http.Response>();
    final inner = MockClient((request) {
      if (!started.isCompleted) started.complete();
      return response.future;
    });
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    gate.bind(inner);
    await Supabase.initialize(url:'https://example.invalid', publishableKey:'test',
      httpClient:gate, authOptions:const FlutterAuthClientOptions(autoRefreshToken:false));
    final client = Supabase.instance.client;
    await client.auth.setInitialSession(jsonEncode(_session(1)));
    await Future<void>.delayed(Duration.zero);
    final old = client.auth.currentSession!, oldJson = jsonEncode(old.toJson());
    var eventCount = 0;
    final sub = client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.tokenRefreshed) eventCount++;
    }, onError: (Object _, StackTrace __) {});
    final refresh = client.auth.refreshSession();
    await started.future.timeout(const Duration(seconds: 2));
    await client.auth.recoverSession(jsonEncode(_session(3)));
    await client.auth.recoverSession(oldJson);
    final restored = client.auth.currentSession!;
    expect(identical(old, restored), isFalse);
    response.complete(http.Response(jsonEncode(_session(2)), 200,
      headers: {'content-type':'application/json'}));
    final result = await refresh.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(identical(result.session, client.auth.currentSession), isFalse);
    expect(identical(client.auth.currentSession, restored), isTrue);
    expect(eventCount, 0);
    await sub.cancel(); await Supabase.instance.dispose();
  });

  test('already-used fallback returns old object without a refresh event', () async {
    SharedPreferences.setMockInitialValues({});
    final inner = MockClient((request) async => http.Response(
      '{"code":"refresh_token_already_used","msg":"synthetic"}', 400, request:request,
      headers: {'content-type':'application/json', 'x-supabase-api-version':'2024-01-01'}));
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    gate.bind(inner);
    await Supabase.initialize(url:'https://example.invalid', publishableKey:'test',
      httpClient:gate, authOptions:const FlutterAuthClientOptions(autoRefreshToken:false));
    final client = Supabase.instance.client;
    await client.auth.setInitialSession(jsonEncode(_session(1)));
    await Future<void>.delayed(Duration.zero);
    final old = client.auth.currentSession!;
    var eventCount = 0;
    final sub = client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.tokenRefreshed) eventCount++;
    }, onError: (Object _, StackTrace __) {});
    final result = await client.auth.refreshSession().timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(identical(result.session, old), isTrue);
    expect(identical(client.auth.currentSession, old), isTrue);
    expect(eventCount, 0);
    await sub.cancel(); await Supabase.instance.dispose();
  });

  test('terminal refresh denial cannot yield a successful refresh receipt', () async {
    SharedPreferences.setMockInitialValues({});
    final inner = MockClient((request) async => http.Response(
      '{"code":"refresh_token_not_found","msg":"synthetic"}', 400, request:request,
      headers: {'content-type':'application/json', 'x-supabase-api-version':'2024-01-01'}));
    final gate = RefreshAdmissionClient(inner, backend: Uri.parse('https://example.invalid'));
    gate.bind(inner);
    await Supabase.initialize(url:'https://example.invalid', publishableKey:'test',
      httpClient:gate, authOptions:const FlutterAuthClientOptions(autoRefreshToken:false));
    final client = Supabase.instance.client;
    await client.auth.setInitialSession(jsonEncode(_session(1)));
    await Future<void>.delayed(Duration.zero);
    final signedOut = Completer<void>();
    var refreshEvents = 0;
    final sub = client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.signedOut && !signedOut.isCompleted) signedOut.complete();
      if (state.event == AuthChangeEvent.tokenRefreshed) refreshEvents++;
    }, onError: (Object _, StackTrace __) {});
    await expectLater(client.auth.refreshSession(), throwsA(isA<AuthException>()));
    await signedOut.future.timeout(const Duration(seconds: 2));
    expect(client.auth.currentSession, isNull);
    expect(refreshEvents, 0);
    await sub.cancel(); await Supabase.instance.dispose();
  });
}
