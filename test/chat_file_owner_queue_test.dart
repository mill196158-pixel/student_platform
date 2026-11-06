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
  test(
      'real async: a denial waits behind an in-flight file read without deadlock',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('owner-queue-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    var block = false;
    final entered = Completer<void>();
    final release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
      if (block) {
        block = false;
        entered.complete();
        await release.future;
      }
      return dir.path;
    });
    final transport = MockClient((request) async => http.Response(
        '{"error":"file_unavailable","reason":"access_denied_v1"}', 403,
        request: request, headers: {'content-type': 'application/json'}));
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    const uid = 'queue-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/queue.png';
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    block = true;
    final read = ChatFileAccess.authorize(url)
        .then((_) => false, onError: (Object _) => true);
    await entered.future.timeout(const Duration(seconds: 2));
    final denial = ChatFileAccess.resolve(url)
        .then((_) => false, onError: (Object _) => true);
    // The write-ahead fence itself waits for the outstanding reader. No
    // network request can revoke access before that fence is durable.
    release.complete();
    await Future.wait([read, denial]).timeout(const Duration(seconds: 3));
    expect(ChatFileAccess.isAccessRevoked(url), isTrue);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(await File('${file.path}.denied').exists(), isTrue);
  });
}
