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
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

class TracedMediaProtection extends MediaCacheProtection {
  TracedMediaProtection({required super.db, required super.root, required super.project,
      required super.databaseToken, required super.currentOwner});
  int acquired = 0, released = 0;
  bool failPin = false, throwPin = false;
  @override
  Future<bool> registerPinned(String uid, String key, bool Function() permit) async {
    if (throwPin) throw StateError('pin failed');
    if (failPin) return false;
    return super.registerPinned(uid, key, permit);
  }
  @override
  Future<String?> acquireRead(String uid, String key, bool Function() permit) async {
    final token = await super.acquireRead(uid, key, permit);
    if (token != null) acquired++;
    return token;
  }
  @override
  Future<void> releaseRead(String uid, String key, String token) async {
    await super.releaseRead(uid, key, token);
    released++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('cached attachment read is pinned and releases its durable lease', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('media-consumer-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/index.db');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/photo.png';
    const uid = 'receipt-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    final transport = MockClient((request) async => http.Response(jsonEncode({
      'url': url, 'accessPolicyVersion': 1, 'cacheable': false, 'expiresIn': 60,
    }), 200, request: request, headers: {'content-type': 'application/json'}));
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
        httpClient: transport, authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    addTearDown(() async {
      ChatFileAccess.mediaProtection = null;
      await Supabase.instance.dispose(); await db.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) await dir.delete(recursive: true);
    });
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final key = ChatFileAccess.keyFor(url)!;
    final digest = sha256.convert(utf8.encode('$uid:$key'));
    final file = File('${dir.path}/authorized_chat_files/$uid/$digest');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    await ChatFileAccess.resolve(url);
    final protection = TracedMediaProtection(db: db, root: dir, project: 'project',
        databaseToken: 'guard', currentOwner: () => ChatFileAccess.userId);
    await protection.initialize();
    ChatFileAccess.mediaProtection = protection;
    expect(await ChatFileAccess.readCachedOnly(url, permit: () => true), [1, 2, 3]);
    expect(protection.acquired, 1);
    expect(protection.released, 1);
    expect((await db.query('media_cache_objects')).single['pinned'], 1);
    expect(await db.query('media_cache_read_leases'), isEmpty);
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => true), file.path);
    expect((await db.query('media_cache_objects')).single['pinned'], 1);
    protection.failPin = true;
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => true), isNull);
    protection.throwPin = true;
    expect(await ChatFileAccess.cachedPathForOpen(url, permit: () => true), isNull);
    expect(await file.readAsBytes(), [1, 2, 3]);
  });
}
