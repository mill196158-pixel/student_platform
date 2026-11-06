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
  test('old logout cleanup cannot erase same-user new-session temp', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('forward-owner-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final entered = Completer<void>(), resume = Completer<void>();
    var block = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      if (block) {
        block = false;
        entered.complete();
        await resume.future;
      }
      return dir.path;
    });
    const uid = 'owner-user',
        sidA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        sidB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/file.bin';
    final transport = MockClient((req) async => http.Response(
        jsonEncode({'url': url, 'accessPolicyVersion': 1, 'cacheable': false}),
        200,
        request: req,
        headers: {'content-type': 'application/json'}));
    ChatFileAccess.debugHttpClientFactory = () => MockClient(
        (req) async => http.Response.bytes([1, 2, 3], 200, request: req));
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      if (!resume.isCompleted) resume.complete();
      ChatFileAccess.debugHttpClientFactory = null;
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sidA);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final data = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await data.parent.create(recursive: true);
    await data.writeAsBytes([1, 2, 3]);
    await File('${data.path}.grant').writeAsString('chat-file-grant-v2:$sidA');
    final old = await ChatFileAccess.forwardTemp(url);
    block = true;
    final cleanup = ChatFileAccess.clear();
    await entered.future.timeout(const Duration(seconds: 3));
    await signInWithFileSession(Supabase.instance.client, uid, sidB);
    final fresh = ChatFileAccess.forwardTemp(url);
    resume.complete();
    await cleanup;
    final current = await fresh.timeout(const Duration(seconds: 5));
    expect(await current.readAsBytes(), [1, 2, 3]);
    await ChatFileAccess.releaseForwardTemp(old.path);
    expect(await current.exists(), isTrue);
    await ChatFileAccess.releaseForwardTemp(current.path);
    expect(await current.exists(), isFalse);
  });
}
