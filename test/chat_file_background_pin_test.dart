import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('cached reads do not wait for deduplicated verified pin; pinned copy works offline', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('background-pin-test-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/index.db');
    await db.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY, project TEXT NOT NULL, sid TEXT NOT NULL)');
    await db.insert('chat_app_guards', {'token': 'guard', 'project': '*', 'sid': ''});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const space = MethodChannel('student_platform/storage_space');
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    messenger.setMockMethodCallHandler(space, (_) async => 2000000);
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/photo.png';
    const uid = 'receipt-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    var accessDenied = false;
    final transport = MockClient((request) async => accessDenied
        ? http.Response(jsonEncode({'error': 'file_unavailable', 'reason': 'access_denied_v1'}), 403,
            request: request, headers: {'content-type': 'application/json'})
        : http.Response(jsonEncode({
      'url': url, 'accessPolicyVersion': 1, 'cacheable': false, 'expiresIn': 60,
    }), 200, request: request, headers: {'content-type': 'application/json'}));
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
        httpClient: transport, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    var gate = Completer<void>();
    var downloads = 0;
    var serverBytes = <int>[9, 9, 9];
    ChatFileAccess.debugHttpClientFactory = () => MockClient((request) async {
      downloads++;
      await gate.future;
      return http.Response.bytes(serverBytes, 200, request: request);
    });
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      ChatFileAccess.mediaProtection = null;
      ChatFileAccess.debugHttpClientFactory = null;
      await Supabase.instance.dispose(); await db.close();
      messenger.setMockMethodCallHandler(paths, null);
      messenger.setMockMethodCallHandler(space, null);
      await root.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final key = ChatFileAccess.keyFor(url)!;
    final digest = sha256.convert(utf8.encode('$uid:$key'));
    final file = File('${root.path}/authorized_chat_files/$uid/$digest');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    final protection = MediaCacheProtection(db: db, root: root,
        project: 'https://example.test', databaseToken: 'guard',
        currentOwner: () => ChatFileAccess.userId);
    await protection.initialize();
    protection.accessRecovery = Future.value(true);
    ChatFileAccess.mediaProtection = protection;
    await ChatFileAccess.resolve(url);
    expect(await ChatFileAccess.readBytes(url).timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(await ChatFileAccess.readBytes(url).timeout(const Duration(seconds: 2)), [1, 2, 3]);
    for (var i = 0; i < 50 && downloads == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(downloads, 1);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await root.list(recursive: true).any((item) => item.path.endsWith('.proof')), isFalse,
        reason: 'bytes from another project must never confirm this cache file');
    serverBytes = [1, 2, 3];
    await ChatFileAccess.resolve(url);
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    bool proof = false;
    for (var i = 0; i < 150 && !proof; i++) {
      proof = await root.list(recursive: true).any((item) => item.path.endsWith('.proof'));
      if (!proof) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(proof, isTrue);
    expect(downloads, 2);
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(downloads, 2, reason: 'durable verified copy must prevent repeat GET');
    await ChatFileAccess.debugWithLegacyMutation(() => file.writeAsBytes([1, 2, 3]), uid: uid, key: key);
    final dirtyFence = PinnedAccessFence(db);
    expect(await dirtyFence.isContentClean(protection.project, uid, key), isFalse);
    await ChatFileAccess.resolve(url);
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    for (var i = 0; i < 150 && !await dirtyFence.isContentClean(protection.project, uid, key); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await dirtyFence.isContentClean(protection.project, uid, key), isTrue,
        reason: 'rewriting identical bytes still requires a verified repin');
    expect(downloads, 3);
    await file.delete();
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), [1, 2, 3]);
    ChatFileAccess.mediaProtection = MediaCacheProtection(db: db, root: root,
        project: 'https://other.test', databaseToken: 'guard',
        currentOwner: () => ChatFileAccess.userId);
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    ChatFileAccess.mediaProtection = protection;
    expect(await ChatFileAccess.readBytes(url).timeout(const Duration(seconds: 2)), [1, 2, 3]);
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => false), isNull);
    accessDenied = true;
    await expectLater(ChatFileAccess.resolve(url), throwsA(anything));
    final fence = PinnedAccessFence(db);
    for (var i = 0; i < 50 && await fence.canRead(protection.project, uid, key); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await fence.canRead(protection.project, uid, key), isFalse);
    if (await file.parent.exists()) await file.parent.delete(recursive: true);
    ChatFileAccess.debugResetProcessMemory();
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull,
        reason: 'durable denial survives purge and process restart');
    accessDenied = false;
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    await ChatFileAccess.resolve(url);
    for (var i = 0; i < 50 && !await fence.canRead(protection.project, uid, key); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await fence.canRead(protection.project, uid, key), isTrue);
    final denied = File('${file.path}.denied');
    await denied.writeAsString('denied');
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    await denied.delete();
    final pinned = await root.list(recursive: true).where((item) => item.path.endsWith('.bin')).single;
    await (pinned as File).writeAsBytes([7]);
    await file.delete();
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    gate = Completer<void>();
    // Switch owner while a retry is waiting on the network.
    await file.writeAsBytes([1, 2, 3]);
    await ChatFileAccess.resolve(url);
    expect(await ChatFileAccess.readBytes(url), [1, 2, 3]);
    for (var i = 0; i < 50 && downloads < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(downloads, 4);
    await signInWithFileSession(Supabase.instance.client, 'other-user', sid);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), isNull);
    expect(await pinned.readAsBytes(), [7], reason: 'old owner job cannot republish after switch');
  }, skip: !const bool.fromEnvironment('PINNED_MEDIA_RUNTIME'));
}
