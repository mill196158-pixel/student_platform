import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  test('atomic batch protects only admitted files and rolls back on owner switch', () async {
    final root = await Directory.systemTemp.createTemp('media-batch-test-');
    final path = '${root.path}/db';
    final db = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    final otherDb = await databaseFactoryFfi.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false));
    var owner = 'a';
    final first = MediaCacheProtection(db: db, root: root, project: 'project', databaseToken: 'guard', currentOwner: () => owner);
    final other = MediaCacheProtection(db: otherDb, root: root, project: 'project', databaseToken: 'other', currentOwner: () => owner);
    await first.initialize();
    await db.execute('CREATE TABLE chat_app_guards (token TEXT NOT NULL, project TEXT NOT NULL, sid TEXT NOT NULL)');
    await db.insert('chat_app_guards', {'token': 'guard', 'project': '*', 'sid': ''});
    final dir = Directory('${root.path}/authorized_chat_files/a'); await dir.create(recursive: true);
    final one = File('${dir.path}/${first.digest('a', 'one')}'), two = File('${dir.path}/${first.digest('a', 'two')}');
    await one.writeAsBytes([1, 1]); await two.writeAsBytes([2, 2, 2]);
    for (final key in ['one', 'two']) {
      expect(await first.registerPinned('a', key, () => true), isTrue);
      expect(await first.unpin('a', key, explicitlyAllowed: true, permit: () => true), isTrue);
    }
    first.debugAfterBatchInsert = () async { owner = 'b'; };
    expect(await first.acquireReadBatch('a', ['one', 'two'], () => true), isNull);
    expect(await db.query('media_cache_read_leases'), isEmpty);
    owner = 'a'; first.debugAfterBatchInsert = null;
    expect(await first.acquireReadBatch('a', ['one', 'missing'], () => true), isNull);
    final batch = await first.acquireReadBatch('a', ['one', 'one'], () => true);
    expect(batch, isNotNull);
    expect(await db.query('media_cache_read_leases'), hasLength(1));
    final freed = await other.evict('a', 1, allOperationsParticipate: true, permit: () => true);
    if (const bool.fromEnvironment('MEDIA_CACHE_EVICTION_QA')) {
      expect(freed, 3); expect(await one.exists(), isTrue); expect(await two.exists(), isFalse);
    } else { expect(freed, 0); }
    await first.releaseReadBatch(batch!); await first.releaseReadBatch(batch);
    expect(await db.query('media_cache_read_leases'), isEmpty);
    await otherDb.close(); await db.close(); await root.delete(recursive: true);
  });
}
