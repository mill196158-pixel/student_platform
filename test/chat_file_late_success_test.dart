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
  test('late verified success restores warm grant after timeout', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('late-success-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    const uid = 'late-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/pic.png';
    final response = Completer<http.Response>();
    var offline = false;
    final transport = MockClient((_) async {
      if (offline) throw const SocketException('offline');
      return response.future;
    });
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      if (!response.isCompleted) response.complete(http.Response('{}', 500));
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<TimeoutException>()));
    expect(await File('${file.path}.pending').exists(), isTrue);
    response.complete(http.Response(
        jsonEncode({'url': url, 'accessPolicyVersion': 1, 'cacheable': false}),
        200,
        headers: {'content-type': 'application/json'}));
    for (var i = 0;
        i < 100 && !await File('${file.path}.grant').exists();
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await File('${file.path}.pending').exists(), isFalse);
    expect(await File('${file.path}.grant').exists(), isTrue);
    ChatFileAccess.debugResetProcessMemory();
    offline = true;
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }, timeout: const Timeout(Duration(seconds: 35)));
}
