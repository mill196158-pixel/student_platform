import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('late settings response cannot restore invalidated clear boundary',
      () async {
    SharedPreferences.setMockInitialValues({});
    final started = Completer<void>(), release = Completer<void>();
    var calls = 0;
    await Supabase.initialize(
        url: 'https://example.invalid',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          calls++;
          final first = calls == 1;
          if (first) {
            started.complete();
            await release.future;
          }
          final value = first ? '2026-01-01T00:00:00Z' : '2026-06-01T00:00:00Z';
          return http.Response(jsonEncode({'cleared_at': value}), 200,
              headers: {'content-type': 'application/json'}, request: request);
        }));
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await DmApi.clearSessionState();
      await Supabase.instance.dispose();
    });
    String part(Object value) =>
        base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final token = '${part({'alg': 'none'})}.${part({
          'sub': 'user',
          'iat': now,
          'exp': now + 3600
        })}.sig';
    await Supabase.instance.client.auth.setInitialSession(jsonEncode({
      'access_token': token,
      'refresh_token': 'test',
      'token_type': 'bearer',
      'expires_at': now + 3600,
      'user': {
        'id': 'user',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2022-01-01T00:00:00Z'
      }
    }));
    final old = DmApi.loadClearedAt('chat');
    await started.future;
    DmApi.invalidateClearedAt('chat');
    expect(await DmApi.loadClearedAt('chat'), DateTime.utc(2026, 6));
    final rejected = expectLater(old, throwsA(isA<StateError>()));
    release.complete();
    await rejected;
    expect(DmApi.debugCachedClearedAt('chat'), DateTime.utc(2026, 6));
    expect(calls, 2);
  });
}
