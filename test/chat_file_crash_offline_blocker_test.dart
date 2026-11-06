import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

// Product requirement: a previously authorized file remains available after
// process death in the middle of revalidation. This intentionally fails until
// the offline-availability vs fail-closed-on-unpersisted-denial tradeoff has
// an independently approved solution. It simulates restart, not a real kill.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runKnownFailure = bool.fromEnvironment('RUN_OFFLINE_CRASH_REGRESSION');
  test('BLOCKER: crash during revalidation retains offline attachment',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('chat-crash-pending-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    final client =
        MockClient((_) async => throw const SocketException('offline'));
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
    const uid = 'crash-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url =
        'https://studentsplatform.storage.yandexcloud.net/chats/test/file.png';
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)}'));
    final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    await File('${file.path}.pending').writeAsString('chat-file-grant-v2:$sid');
    ChatFileAccess.debugResetProcessMemory();
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
  },
      skip: runKnownFailure
          ? false
          : 'Known blocker: pending access check after a simulated crash requires online recovery. Run with --dart-define=RUN_OFFLINE_CRASH_REGRESSION=true to reproduce.');
}
