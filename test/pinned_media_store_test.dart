import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_media_store.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:crypto/crypto.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('migration requires project-bound proof and preserves legacy bytes', () async {
    final root = await Directory.systemTemp.createTemp('pin-media-test-');
    final support = Directory('${root.path}/support');
    await support.create();
    final db = await databaseFactoryFfi.openDatabase('${root.path}/test.db');
    addTearDown(() async { await db.close(); await root.delete(recursive: true); });
    var current = true, verified = false;
    var available = 2000000;
    final legacy = MediaCacheProtection(db: db, root: root,
        project: 'https://first.example/', databaseToken: 'test', currentOwner: () => 'uid');
    final folder = Directory('${root.path}/authorized_chat_files/uid');
    await folder.create(recursive: true);
    final file = File('${folder.path}/${legacy.digest('uid', 'key')}');
    await file.writeAsBytes([1, 2, 3, 4]);
    PinnedMediaStore store(String project, MediaCacheProtection source) => PinnedMediaStore(
      db: db, supportRoot: support, legacy: source, project: project,
      uid: 'uid', sessionId: 'session', permit: () => current,
      freeBytes: (_) async => available,
      verifyLegacyProvenance: (file, p, u, s, k) async => verified && p == 'https://first.example');
    final first = store('https://first.example', legacy);
    expect(await first.pinFromLegacy('key'), isFalse);
    expect(await first.readPinned('key'), isNull);
    verified = true;
    available = 1;
    expect(await first.pinFromLegacy('key'), isFalse);
    available = 2000000;
    first.debugAfterCopy = () async { await file.writeAsBytes([9]); };
    expect(await first.pinFromLegacy('key'), isFalse);
    await file.writeAsBytes([1, 2, 3, 4]);
    first.debugAfterCopy = () async { current = false; };
    expect(await first.pinFromLegacy('key'), isFalse);
    current = true;
    first.debugAfterCopy = null;
    expect(await first.pinFromLegacy('key'), isTrue);
    expect(await first.readPinned('key'), [1, 2, 3, 4]);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    current = false;
    expect(await first.readPinned('key'), isNull);
    current = true;
    final other = MediaCacheProtection(db: db, root: root,
        project: 'https://second.example', databaseToken: 'test', currentOwner: () => 'uid');
    final second = store('https://second.example', other);
    expect(await second.readPinned('key'), isNull);
    expect(await second.pinFromLegacy('key'), isFalse);
    final pinned = await support.list(recursive: true).where((e) => e.path.endsWith('.bin')).single;
    await (pinned as File).writeAsBytes([8, 8]);
    expect(await first.readPinned('key'), isNull);
    expect(await first.pinFromLegacy('key'), isFalse);
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    await file.writeAsBytes([5, 6, 7]);
    expect(await first.pinFromLegacy('key'), isTrue);
    expect(await first.readPinned('key'), [5, 6, 7]);
    expect(await support.list(recursive: true).where((e) => e.path.endsWith('.bin')).length, 2);
  });

  test('two handles cannot publish an older version over a newer one', () async {
    final root = await Directory.systemTemp.createTemp('pin-cas-test-');
    final support = Directory('${root.path}/support'); await support.create();
    final db1 = await databaseFactoryFfi.openDatabase('${root.path}/db', options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/db', options: OpenDatabaseOptions(singleInstance: false));
    final legacy1 = MediaCacheProtection(db: db1, root: root, project: 'https://first.example',
      databaseToken: 'a', currentOwner: () => 'uid');
    final legacy2 = MediaCacheProtection(db: db2, root: root, project: 'https://first.example',
      databaseToken: 'b', currentOwner: () => 'uid');
    final folder = Directory('${root.path}/authorized_chat_files/uid'); await folder.create(recursive: true);
    final file = File('${folder.path}/${legacy1.digest('uid', 'key')}'); await file.writeAsBytes([1]);
    PinnedMediaStore store(Database db, MediaCacheProtection legacy) => PinnedMediaStore(
      db: db, supportRoot: support, legacy: legacy, project: 'https://first.example',
      uid: 'uid', sessionId: 'session', permit: () => true, freeBytes: (_) async => 2000000,
      verifyLegacyProvenance: (_, __, ___, ____, _____) async => true);
    final old = store(db1, legacy1), newer = store(db2, legacy2);
    final started = Completer<void>(), release = Completer<void>();
    old.debugBeforePublish = () async { started.complete(); await release.future; };
    final oldJob = old.pinFromLegacy('key');
    await started.future;
    await file.writeAsBytes([2]);
    expect(await newer.pinFromLegacy('key'), isTrue);
    release.complete();
    expect(await oldJob, isFalse);
    expect(await newer.readPinned('key'), [2]);
    await db1.close(); await db2.close(); await root.delete(recursive: true);
  });

  test('old session proof cannot authorize another session newer version', () async {
    final root = await Directory.systemTemp.createTemp('pin-sid-version-');
    final support = Directory('${root.path}/support'); await support.create();
    final db = await databaseFactoryFfi.openDatabase('${root.path}/db', options: OpenDatabaseOptions(singleInstance: false));
    final db2 = await databaseFactoryFfi.openDatabase('${root.path}/db', options: OpenDatabaseOptions(singleInstance: false));
    final legacy = MediaCacheProtection(db: db, root: root, project: 'https://first.example', databaseToken: 'guard', currentOwner: () => 'uid');
    final otherLegacy = MediaCacheProtection(db: db2, root: root, project: 'https://first.example', databaseToken: 'other', currentOwner: () => 'uid');
    final dir = Directory('${root.path}/authorized_chat_files/uid'); await dir.create(recursive: true);
    final file = File('${dir.path}/${legacy.digest('uid', 'key')}'); await file.writeAsBytes([1]);
    PinnedMediaStore store(String sid, Database handle, MediaCacheProtection source) => PinnedMediaStore(db: handle, supportRoot: support, legacy: source,
      project: 'https://first.example', uid: 'uid', sessionId: sid, permit: () => true,
      freeBytes: (_) async => 2000000, verifyLegacyProvenance: (_, __, ___, ____, _____) async => true);
    final first = store('sid-a', db, legacy), second = store('sid-b', db2, otherLegacy), fence = PinnedAccessFence(db);
    expect(await first.pinFromLegacy('key'), isTrue);
    await file.writeAsBytes([2]);
    expect(await second.pinFromLegacy('key'), isTrue);
    await db.execute('UPDATE pinned_fence_state SET denied=0');
    expect(await fence.canRead('https://first.example', 'uid', 'key', checksum: sha256.convert([1]).toString()), isFalse);
    expect(await fence.canRead('https://first.example', 'uid', 'key', checksum: sha256.convert([2]).toString()), isTrue);
    expect(await first.readPinned('key'), [1]); // Raw archive alone is never an authorization.
    expect(await second.readPinned('key'), [2]);
    await db2.close(); await db.close(); await root.delete(recursive: true);
  });
}
