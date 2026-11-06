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
  test('forward temp is not returned after access revoked during write',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('forward-fence-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    const uid = 'forward-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/file.bin';
    var deny = false;
    final transport = MockClient((req) async => deny
        ? http.Response(
            '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
            request: req, headers: {'content-type': 'application/json'})
        : http.Response(
            jsonEncode(
                {'url': url, 'accessPolicyVersion': 1, 'cacheable': false}),
            200,
            request: req,
            headers: {'content-type': 'application/json'}));
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final reached = Completer<void>(), resume = Completer<void>();
    ChatFileAccess.debugBeforeForwardReturn = () async {
      reached.complete();
      await resume.future;
    };
    addTearDown(() async {
      ChatFileAccess.debugBeforeForwardReturn = null;
      if (!resume.isCompleted) resume.complete();
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final data = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await data.parent.create(recursive: true);
    await data.writeAsBytes([1, 2, 3]);
    await File('${data.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    final forward = ChatFileAccess.forwardTemp(url);
    final failed = expectLater(forward, throwsStateError);
    await reached.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    deny = true;
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<FunctionException>()));
    resume.complete();
    await failed;
    expect(await data.readAsBytes(), [1, 2, 3]);
  });
}
