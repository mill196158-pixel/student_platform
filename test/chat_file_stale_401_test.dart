import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('old session 401 cannot revoke the current session', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('stale-401-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    const uid = 'auth-user',
        url =
            'https://studentsplatform.storage.yandexcloud.net/chats/test/file.png';
    final entered = Completer<void>(), old = Completer<http.Response>();
    var requests = 0;
    final transport = MockClient((req) async {
      requests++;
      if (requests == 1) {
        entered.complete();
        return old.future;
      }
      return http.Response(
          jsonEncode(
              {'url': url, 'accessPolicyVersion': 1, 'cacheable': false}),
          200,
          request: req,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      if (!old.isCompleted) old.complete(http.Response('{}', 500));
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(
        Supabase.instance.client, uid, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    final pending = ChatFileAccess.resolve(url);
    final error = expectLater(pending, throwsA(isA<FunctionException>()));
    await entered.future.timeout(const Duration(seconds: 3));
    await signInWithFileSession(
        Supabase.instance.client, uid, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    old.complete(http.Response('{"error":"unauthorized"}', 401,
        headers: {'content-type': 'application/json'}));
    await error;
    expect(ChatFileAccess.isAccessRevoked(url), isFalse);
    expect(await ChatFileAccess.resolve(url), url);
  });
}
