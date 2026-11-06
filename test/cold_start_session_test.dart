import 'package:student_platform/src/core/coordinated_refresh_client.dart';
import 'package:student_platform/src/core/refresh_security_fence.dart';
import 'package:student_platform/src/core/transport_failure.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
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
  test('classifies transport separately from server rejections', () async {
    final client = SupabaseClient('https://example.com', 'test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    addTearDown(client.dispose);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await client.auth.setInitialSession(jsonEncode(sessionFixture(now - 60)));
    for (final error in [
      const SocketException('offline'),
      http.ClientException('offline'),
      TimeoutException('offline'),
      AuthRetryableFetchException(statusCode: '503'),
    ]) {
      expect(
          await AuthSession.restoreSessionStatus(client,
              refresh: () async => throw error),
          SessionRestoreStatus.transportFailure);
    }
    for (final error in [
      const AuthApiException('invalid', statusCode: '400'),
      const AuthApiException('denied', statusCode: '401'),
      const AuthApiException('denied', statusCode: '403'),
      StateError('invalid data'),
    ]) {
      expect(
          await AuthSession.restoreSessionStatus(client,
              refresh: () async => throw error),
          SessionRestoreStatus.rejected);
    }
  });

  test('a delayed network failure from an old session is ignored', () async {
    final client = SupabaseClient('https://example.com', 'test-public-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    addTearDown(client.dispose);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await client.auth.setInitialSession(jsonEncode(sessionFixture(now - 60)));
    final delayed = Completer<AuthResponse>();
    final result =
        AuthSession.restoreSessionStatus(client, refresh: () => delayed.future);
    final newer = sessionFixture(now + 3600);
    (newer['user'] as Map<String, dynamic>)['id'] = 'other-user';
    await client.auth.setInitialSession(jsonEncode(newer));
    delayed.completeError(TimeoutException('offline'));
    expect(await result, SessionRestoreStatus.stale);
  });

  test('late rejection and success from old session cannot replace new account',
      () async {
    for (final success in [false, true]) {
      final client = SupabaseClient('https://example.com', 'test-public-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false));
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await client.auth.setInitialSession(jsonEncode(sessionFixture(now - 60)));
      final delayed = Completer<AuthResponse>();
      final pending = AuthSession.restoreSessionStatus(client,
          refresh: () => delayed.future);
      final newer = sessionFixture(now + 3600);
      (newer['user'] as Map<String, dynamic>)['id'] = 'other-user';
      await client.auth.setInitialSession(jsonEncode(newer));
      if (success) {
        delayed.complete(AuthResponse(
            session: Session.fromJson(
                jsonDecode(jsonEncode(sessionFixture(now + 3600)))
                    as Map<String, dynamic>)));
      } else {
        delayed
            .completeError(const AuthApiException('denied', statusCode: '401'));
      }
      expect(await pending, SessionRestoreStatus.stale);
      expect(client.auth.currentUser?.id, 'other-user');
      await client.dispose();
    }
  });

  test('real SDK delayed refresh cannot redirect after a new sign-in',
      () async {
    for (final status in [200, 401]) {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final entered = Completer<void>();
      final oldResponse = Completer<http.Response>();
      final newer = sessionFixture(now + 3600);
      (newer['user'] as Map<String, dynamic>)['id'] = 'other-user';
      final client = SupabaseClient('https://example.com', 'test-public-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) {
        if (request.url.queryParameters['grant_type'] == 'refresh_token') {
          entered.complete();
          return oldResponse.future;
        }
        return Future.value(http.Response(jsonEncode(newer), 200,
            headers: {'content-type': 'application/json'}));
      }));
      await client.auth.setInitialSession(jsonEncode(sessionFixture(now - 60)));
      final pending = AuthSession.restoreSessionStatus(client);
      await entered.future;
      await client.auth
          .signInWithPassword(email: 'test@example.com', password: 'test');
      oldResponse.complete(http.Response(
          jsonEncode(
              status == 200 ? sessionFixture(now + 3600) : {'msg': 'denied'}),
          status,
          headers: {'content-type': 'application/json'}));
      expect(await pending, SessionRestoreStatus.stale);
      expect(client.auth.currentUser?.id, 'other-user');
      await client.dispose();
    }
  });
  test('SDK masks fence error but its revision blocks offline admission',
      () async {
    expect(
        isTemporaryTransportFailure(RefreshSecurityFenceException()), isFalse);
    final fence = RefreshSecurityFence();
    final gate = RefreshAdmissionClient(
        MockClient((_) async => http.Response('', 200)),
        backend: Uri.parse('https://example.invalid'),
        securityFence: fence);
    gate.block();
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: gate);
    final subscription =
        client.auth.onAuthStateChange.listen((_) {}, onError: (_) {});
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await client.auth.setInitialSession(jsonEncode(sessionFixture(now - 60)));
    final revision = fence.revision;
    final status = await AuthSession.restoreSessionStatus(client);
    expect(status, SessionRestoreStatus.transportFailure);
    expect(fence.unchangedSince(revision), isFalse);
    expect(client.auth.currentSession, isNotNull);
    await subscription.cancel();
    await client.dispose();
  }, timeout: const Timeout(Duration(seconds: 50)));

  test('real SDK confirmed 401 clears the expired session', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var requests = 0;
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      requests++;
      return http.Response(
          jsonEncode(
              {'msg': 'revoked', 'error_code': 'refresh_token_not_found'}),
          401,
          request: request,
          headers: {'content-type': 'application/json'});
    }));
    final subscription =
        client.auth.onAuthStateChange.listen((_) {}, onError: (_) {});
    await client.auth.setInitialSession(jsonEncode(sessionFixture(now - 60)));
    final status = await AuthSession.restoreSessionStatus(client);
    expect(requests, greaterThan(0));
    expect(status, SessionRestoreStatus.stale);
    expect(client.auth.currentSession, isNull);
    await subscription.cancel();
    await client.dispose();
  });

  test('real SDK offline refresh preserves an expired saved session', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var requests = 0;
    final client = SupabaseClient('https://example.invalid', 'test',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      requests++;
      throw const SocketException('synthetic offline');
    }));
    final subscription =
        client.auth.onAuthStateChange.listen((_) {}, onError: (_) {});
    await client.auth.setInitialSession(jsonEncode(sessionFixture(now - 60)));
    expect(client.auth.currentSession!.isExpired, isTrue);
    final status = await AuthSession.restoreSessionStatus(client);
    expect(requests, greaterThan(0));
    expect(status, SessionRestoreStatus.transportFailure);
    expect(client.auth.currentSession?.user.id, 'test-user');
    expect(client.auth.currentSession!.isExpired, isTrue);
    await subscription.cancel();
    await client.dispose();
  }, timeout: const Timeout(Duration(seconds: 50)));
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
