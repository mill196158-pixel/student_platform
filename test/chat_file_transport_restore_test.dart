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
  test('completed transport failure restores verified receipt for restart',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('offline-restore-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    const uid = 'offline-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/copy.png';
    final entered = Completer<void>(), response = Completer<http.Response>();
    var immediateOffline = false;
    var serviceUnavailable = false;
    final transport = MockClient((_) async {
      if (immediateOffline) throw const SocketException('offline');
      if (serviceUnavailable)
        return http.Response(
            '{"error":"service_unavailable","accessPolicyVersion":1}', 503,
            headers: {'content-type': 'application/json'});
      if (!entered.isCompleted) entered.complete();
      return response.future;
    });
    await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      if (!response.isCompleted)
        response.completeError(const SocketException('offline'));
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
    final resolution = ChatFileAccess.resolve(url);
    final fails = expectLater(resolution, throwsA(isA<SocketException>()));
    await entered.future;
    expect(await File('${file.path}.pending').exists(), isTrue);
    expect(await File('${file.path}.grant').exists(), isFalse);
    response.completeError(const SocketException('offline'));
    await fails;
    expect(await File('${file.path}.pending').exists(), isFalse);
    expect(await File('${file.path}.grant').exists(), isTrue);
    ChatFileAccess.debugResetProcessMemory();
    immediateOffline = true;
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    immediateOffline = false;
    serviceUnavailable = true;
    await expectLater(
        ChatFileAccess.resolve(url), throwsA(isA<FunctionException>()));
    expect(await File('${file.path}.grant').exists(), isTrue);
    ChatFileAccess.debugResetProcessMemory();
    immediateOffline = true;
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
}
