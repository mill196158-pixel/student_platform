import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_media_store.dart';

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
  });
}
