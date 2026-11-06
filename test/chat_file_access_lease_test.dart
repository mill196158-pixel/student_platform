import 'dart:io';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('recent cacheable grant avoids duplicate resolve; other files do not',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('chat-lease-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final key = (jsonDecode(request.body) as Map)['key'] as String;
      return http.Response(
          jsonEncode({
            'url': 'https://studentsplatform.storage.yandexcloud.net/$key',
            'accessPolicyVersion': 1,
            'cacheable': !key.contains('sensitive'),
            'expiresIn': key.contains('invalid-ttl')
                ? 0
                : (key.contains('short-ttl') ? 1 : 60),
          }),
          200,
          request: request,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: client,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, 'test-user',
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    const normal =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/image.jpg';
    const special =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/sensitive.jpg';
    expect(await ChatFileAccess.resolve(normal), normal);
    expect(await ChatFileAccess.resolve(normal), normal);
    expect(calls, 1);
    // The ordinary non-cacheable response remains usable online.
    expect(await ChatFileAccess.resolve(special), special);
    expect(await ChatFileAccess.resolve(special), special);
    expect(calls, 3);
    const invalidTtl =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/invalid-ttl.jpg';
    expect(await ChatFileAccess.resolve(invalidTtl), invalidTtl);
    expect(await ChatFileAccess.resolve(invalidTtl), invalidTtl);
    expect(calls, 5);
    ChatFileAccess.generation++;
    expect(await ChatFileAccess.resolve(normal), normal);
    expect(calls, 6);
    const shortTtl =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/short-ttl.jpg';
    expect(await ChatFileAccess.resolve(shortTtl), shortTtl);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(await ChatFileAccess.resolve(shortTtl), shortTtl);
    expect(calls, 8);
    await signInWithFileSession(Supabase.instance.client, 'different-user',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    expect(await ChatFileAccess.resolve(normal), normal);
    expect(calls, 9);
  });
}
