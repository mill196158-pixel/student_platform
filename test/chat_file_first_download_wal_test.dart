import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
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
  test('first download keeps WAL while older request can still deny', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('first-file-wal-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    const uid = 'new-file-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/new.png';
    final first = Completer<http.Response>();
    var requests = 0;
    var offline = false;
    final transport = MockClient((req) async {
      if (offline) throw const SocketException('offline');
      requests++;
      if (requests == 1) return first.future;
      return http.Response(
          jsonEncode({
            'url': url,
            'accessPolicyVersion': 1,
            'cacheable': false,
            'expiresIn': 60
          }),
          200,
          request: req,
          headers: {'content-type': 'application/json'});
    });
    ChatFileAccess.debugHttpClientFactory = () => MockClient(
        (req) async => http.Response.bytes([1, 2, 3], 200, request: req));
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      ChatFileAccess.debugHttpClientFactory = null;
      ChatFileAccess.debugFailDenialPersistence = false;
      if (!first.isCompleted) first.complete(http.Response('{}', 500));
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final data = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<TimeoutException>()));
    expect(await File('${data.path}.pending').exists(), isTrue);
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    expect(await data.readAsBytes(), [1, 2, 3]);
    expect(await File('${data.path}.grant').exists(), isFalse);
    ChatFileAccess.debugFailDenialPersistence = true;
    first.complete(http.Response(
        '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
        headers: {'content-type': 'application/json'}));
    for (var i = 0; i < 100 && !ChatFileAccess.isAccessRevoked(url); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ChatFileAccess.isAccessRevoked(url), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await File('${data.path}.pending').exists(), isTrue);
    expect(await File('${data.path}.grant').exists(), isFalse);
    expect(await data.readAsBytes(), [1, 2, 3]);
    ChatFileAccess.debugResetProcessMemory();
    offline = true;
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    expect(await data.readAsBytes(), [1, 2, 3]);
  }, timeout: const Timeout(Duration(seconds: 35)));
}
