import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_media_store.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  test('legacy writer on another handle waits for archive publication', () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'https://first.example', publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final root = await Directory.systemTemp.createTemp('pin-writer-fence-');
    final support = Directory('${root.path}/support'); await support.create();
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/db', options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/db', options: OpenDatabaseOptions(singleInstance: false));
    await db2.rawQuery('PRAGMA busy_timeout=100');
    await db1.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY, project TEXT NOT NULL, sid TEXT NOT NULL)');
    await db1.insert('chat_app_guards', {'token': 'b', 'project': '*', 'sid': ''});
    final fence = PinnedAccessFence(db2, databaseToken: 'b');
    final initial = await fence.begin('https://first.example', 'uid', 'key');
    await fence.finish(initial, allowed: true);
    final a = MediaCacheProtection(db: db1, root: root, project: 'https://first.example', databaseToken: 'a', currentOwner: () => 'uid');
    final b = MediaCacheProtection(db: db2, root: root, project: 'https://first.example', databaseToken: 'b', currentOwner: () => 'uid');
    final folder = Directory('${root.path}/authorized_chat_files/uid'); await folder.create(recursive: true);
    final file = File('${folder.path}/${a.digest('uid', 'key')}'); await file.writeAsBytes([1]);
    final archive = PinnedMediaStore(db: db1, supportRoot: support, legacy: a,
        project: 'https://first.example', uid: 'uid', sessionId: 'sid', permit: () => true,
        freeBytes: (_) async => 2000000, verifyLegacyProvenance: (_, __, ___, ____, _____) async => true);
    final entered = Completer<void>(), release = Completer<void>();
    archive.debugDuringPublish = () async { entered.complete(); await release.future; };
    ChatFileAccess.mediaProtection = b;
    final pin = archive.pinFromLegacy('key');
    await entered.future;
    var written = false;
    final writer = ChatFileAccess.debugWithLegacyMutation(() async { await file.writeAsBytes([2]); written = true; }, uid: 'uid', key: 'key')
        .then((_) => true, onError: (Object _) => false);
    expect(await writer, isFalse);
    expect(written, isFalse);
    release.complete();
    expect(await pin, isTrue);
    await ChatFileAccess.debugWithLegacyMutation(() async { await file.writeAsBytes([2]); written = true; }, uid: 'uid', key: 'key');
    expect(written, isTrue);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isFalse);
    expect(await archive.readPinned('key'), [1]);
    final allowWithoutPin = await fence.begin('https://first.example', 'uid', 'key');
    await fence.finish(allowWithoutPin, allowed: true);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isFalse,
        reason: 'access allow must not clear dirty content');
    archive.debugDuringPublish = null;
    expect(await archive.pinFromLegacy('key'), isTrue);
    expect(await archive.readPinned('key'), [2]);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isTrue);
    await expectLater(ChatFileAccess.debugWithLegacyMutation<void>(() async {
      throw const FileSystemException('failure before rename');
    }, uid: 'uid', key: 'key'), throwsA(isA<FileSystemException>()));
    expect(await db2.query('pinned_fence_pending'), isEmpty);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isFalse);
    expect(await archive.pinFromLegacy('key'), isTrue);
    final allowRetry = await fence.begin('https://first.example', 'uid', 'key');
    await fence.finish(allowRetry, allowed: true);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isTrue);
    await expectLater(ChatFileAccess.debugWithLegacyMutation<void>(() async {
      await file.writeAsBytes([3]);
      throw const FileSystemException('failure after rename');
    }, uid: 'uid', key: 'key'), throwsA(isA<FileSystemException>()));
    expect(await db2.query('pinned_fence_pending'), isEmpty);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isFalse);
    expect(await archive.pinFromLegacy('key'), isTrue);
    final allowFinal = await fence.begin('https://first.example', 'uid', 'key');
    await fence.finish(allowFinal, allowed: true);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isTrue);
    PinnedAccessFence.debugFailMutationAttempts = 1;
    await expectLater(ChatFileAccess.debugWithLegacyMutation<void>(() async {
      throw const FileSystemException('injected writer failure');
    }, uid: 'uid', key: 'key'), throwsA(isA<FileSystemException>()));
    expect(await db2.query('pinned_fence_pending'), hasLength(1));
    for (var i = 0; i < 100 && (await db2.query('pinned_fence_pending')).isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await db2.query('pinned_fence_pending'), isEmpty);
    expect(await fence.canRead('https://first.example', 'uid', 'key'), isFalse);
    ChatFileAccess.mediaProtection = null;
    await db1.close(); await db2.close(); await Supabase.instance.dispose();
    await root.delete(recursive: true);
  }, skip: !const bool.fromEnvironment('PINNED_MEDIA_RUNTIME'));
}
