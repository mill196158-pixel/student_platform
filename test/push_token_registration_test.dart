import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test(
      'Android capability registration falls back only on missing RPC for a current owner',
      () async {
    var status = 200;
    var current = true;
    var revoke = false;
    final calls = <String>[];
    final client = SupabaseClient('https://example.invalid', 'test',
        httpClient: MockClient((request) async {
      calls.add(request.url.pathSegments.last);
      if (revoke) current = false;
      final code = request.url.path.endsWith('_v2') ? status : 200;
      return http.Response(
          code == 200
              ? 'null'
              : '{"message":"registration error","code":"${code == 404 ? 'PGRST202' : '42501'}"}',
          code,
          headers: {'Content-Type': 'application/json'},
          request: request);
    }));
    addTearDown(client.dispose);
    Future<void> register(String platform) =>
        registerDevicePushToken(client, {'p_platform': platform},
            isCurrent: () => current);
    const modern = 'register_android_push_token_v2';
    const legacy = 'register_device_push_token';
    await register('android');
    expect(calls, [modern]);
    calls.clear();
    status = 404;
    await register('android');
    expect(calls, [modern, legacy]);
    calls.clear();
    status = 403;
    await expectLater(register('android'), throwsA(isA<PostgrestException>()));
    expect(calls, [modern]);
    calls.clear();
    await register('ios');
    expect(calls, [legacy]);
    calls.clear();
    status = 404;
    revoke = true;
    await register('android');
    expect(calls, [modern]);
  });
  test(
      'transient registration failure and a later granted permission retry on resume',
      () async {
    var attempts = 0;
    final registration = PushTokenRegistration(() async {
      attempts++;
      if (attempts == 1) throw StateError('temporarily offline');
      return attempts >= 3;
    });
    await registration.ensure();
    await registration.ensure();
    await registration.ensure();
    await registration.ensure();
    expect(attempts, 3);
  });

  test(
      'rotation during old token upsert is serialized and registers latest token',
      () async {
    var attempts = 0;
    final pending = Completer<bool>();
    final registration = PushTokenRegistration(() async {
      attempts++;
      return attempts == 1 ? pending.future : true;
    });
    final before = registration.ensure();
    final after = registration.ensure(tokenChanged: true);
    final resume = registration.ensure();
    expect(attempts, 1);
    pending.complete(true);
    await Future.wait([before, after, resume]);
    expect(attempts, 2);
    await registration.ensure();
    expect(attempts, 2);
  });
}
