import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/core/auth_session.dart';

Map<String, dynamic> sessionFixture(int expiry) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return {
    'access_token': '${part({'alg': 'HS256'})}.${part({
          'sub': 'test-user',
          'exp': expiry
        })}.sig',
    'refresh_token': 'test-refresh',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': expiry,
    'user': {
      'id': 'test-user',
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-01-01T00:00:00Z',
    },
  };
}

void main() {
  for (final scenario in ['valid', 'expired', 'rejected', 'missing']) {
    test('cold session restore: $scenario', () async {
      var requests = 0;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final client = SupabaseClient('https://example.com', 'test-public-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
        requests++;
        expect(request.url.path, '/auth/v1/token');
        expect(request.url.queryParameters['grant_type'], 'refresh_token');
        expect(jsonDecode(request.body)['refresh_token'], 'test-refresh');
        return http.Response(
            jsonEncode(scenario == 'rejected'
                ? {
                    'msg': 'Invalid Refresh Token',
                    'code': 'refresh_token_not_found'
                  }
                : sessionFixture(now + 3600)),
            scenario == 'rejected' ? 400 : 200,
            request: request,
            headers: {'content-type': 'application/json'});
      }));
      addTearDown(client.dispose);
      if (scenario != 'missing') {
        await client.auth.setInitialSession(jsonEncode(
            sessionFixture(now + (scenario == 'valid' ? 3600 : -60))));
      }
      expect(await AuthSession.tryRestoreSession(client),
          scenario == 'valid' || scenario == 'expired');
      expect(requests, scenario == 'expired' || scenario == 'rejected' ? 1 : 0);
      if (scenario == 'expired') {
        expect(client.auth.currentSession!.isExpired, isFalse);
      }
    });
  }
}
