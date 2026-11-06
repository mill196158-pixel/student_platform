import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('cached-only read checks owner, receipt and permit without network', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('cached-read-test-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => dir.path);
    var requests = 0;
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
      httpClient: MockClient((_) async { requests++; throw const SocketException('offline'); }),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      await Supabase.instance.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, null);
      if (await dir.exists()) {
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final resolved = await dir.resolveSymbolicLinks();
        if (!p.isWithin(root, resolved) || !p.basename(resolved).startsWith('cached-read-test-')) {
          throw StateError('Unsafe test cleanup target');
        }
        await dir.delete(recursive: true);
      }
    });
    const uid = 'cache-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/file.png';
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final key = ChatFileAccess.keyFor(url)!;
    final digest = sha256.convert(utf8.encode('$uid:$key'));
    final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    await File('${file.path}.grant').writeAsString('chat-file-grant-v2:$sid');
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), [1, 2, 3]);
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => true), file.path);
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => false), isNull);
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => false), isNull);
    // A process restart loses the in-memory proof for an unfinished check.
    // Keep the original bytes but do not infer a grant or use the network.
    await File('${file.path}.grant').rename('${file.path}.pending');
    ChatFileAccess.debugResetProcessMemory();
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => true), isNull);
    expect(await file.readAsBytes(), [1, 2, 3]);
    await File('${file.path}.pending').rename('${file.path}.grant');
    await File('${file.path}.denied').writeAsString('revoked');
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => true), isNull);
    expect(await file.readAsBytes(), [1, 2, 3]);
    await File('${file.path}.denied').delete();
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), [1, 2, 3]);
    var permitChecks = 0;
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => ++permitChecks < 3), isNull);
    expect(permitChecks, greaterThanOrEqualTo(3));
    await signInWithFileSession(Supabase.instance.client, 'other-owner',
        'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => true), isNull);
    expect(requests, 0);
  });
}
