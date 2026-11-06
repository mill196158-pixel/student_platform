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
  test('late denial revokes a warm grant without deleting the cached file',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir =
        await Directory.systemTemp.createTemp('chat-file-offline-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    final pending = Completer<http.Response>();
    var denied = false;
    var offline = false;
    var nonCacheable = false;
    var secondSuccess = false;
    var calls = 0;
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/chat-file-access')) {
        calls++;
        if (offline) throw const SocketException('offline');
        if (nonCacheable) {
          return http.Response(
              jsonEncode({
                'url':
                    'https://studentsplatform.storage.yandexcloud.net/chats/test/photo.png',
                'cacheable': false
              }),
              200,
              request: request,
              headers: {'content-type': 'application/json'});
        }
        if (secondSuccess) {
          return http.Response(
              jsonEncode({
                'url':
                    'https://studentsplatform.storage.yandexcloud.net/chats/test/photo.png',
                'accessPolicyVersion': 1,
                'cacheable': true,
                'expiresIn': 60,
              }),
              200,
              request: request,
              headers: {'content-type': 'application/json'});
        }
        if (denied) {
          return http.Response(
              '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
              request: request, headers: {'content-type': 'application/json'});
        }
        return pending.future;
      }
      return http.Response('{}', 404,
          request: request, headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      if (!pending.isCompleted) pending.complete(http.Response('{}', 500));
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await signInWithFileSession(Supabase.instance.client, 'test-user', sid);
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/photo.png';
    final key = ChatFileAccess.keyFor(url)!;
    final digest = sha256.convert(utf8.encode('test-user:$key'));
    final file = File('${dir.path}/authorized_chat_files/test-user/$digest');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');

    final copies = await Future.wait(
        List.generate(3, (_) => ChatFileAccess.readBytes(url)));
    expect(copies, everyElement([1, 2, 3]));
    for (var i = 0; i < 100 && calls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(calls, 1);
    // Local display is instant; wait for the independent server request to
    // time out before starting a newer successful authorization.
    await Future<void>.delayed(const Duration(milliseconds: 15100));
    secondSuccess = true;
    expect(await ChatFileAccess.resolve(url), url);
    expect(await ChatFileAccess.resolve(url), url);
    expect(calls, 2);
    // The old timed-out request still owns a durable pending fence even
    // though a later request succeeded.
    expect(await File('${file.path}.pending').exists(), isTrue);
    pending.complete(http.Response(
        '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
        headers: {'content-type': 'application/json'}));
    final deniedMarker = File('${file.path}.denied');
    for (var i = 0; i < 30 && !await deniedMarker.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await deniedMarker.exists(), isTrue);
    expect(await file.exists(), isTrue);
    offline = true;
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<SocketException>()));
    offline = false;
    secondSuccess = false;
    denied = true;
    await expectLater(
        ChatFileAccess.readBytes(url), throwsA(isA<FunctionException>()));
    expect(await file.exists(), isTrue);

    // A session switch while non-cacheable cleanup is waiting must not return
    // the old signed URL, including to a caller of resolve() directly.
    denied = false;
    nonCacheable = true;
    final entered = Completer<void>();
    final resume = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) {
      if (!entered.isCompleted) entered.complete();
      return resume.future;
    });
    final result = ChatFileAccess.resolve(url);
    final rejected = expectLater(result, throwsStateError);
    await entered.future;
    ChatFileAccess.generation++;
    resume.complete(dir.path);
    await rejected;
  }, timeout: const Timeout(Duration(seconds: 35)));
}
