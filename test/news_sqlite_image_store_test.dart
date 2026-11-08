import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_ui/student_ui.dart';

Future<void> _writeIsolated(String root, String path, int value) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase('$root/store.db',
      options: OpenDatabaseOptions(singleInstance: false));
  try {
    final store = NewsSqliteImageStore(database: db, root: Directory('$root/blobs'));
    final key = NewsImageCacheKey(path: path, version: '1');
    if (!await store.put(key, Uint8List.fromList([value]), await store.capture(key))) {
      throw StateError('Synthetic publication rejected');
    }
  } finally { await db.close(); }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('two handles preserve both publications and stale tickets are rejected', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-');
    final dbA = await databaseFactoryFfi.openDatabase('${dir.path}/store.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final dbB = await databaseFactoryFfi.openDatabase('${dir.path}/store.db',
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
    final a = NewsSqliteImageStore(database: dbA, root: Directory('${dir.path}/blobs'));
    final b = NewsSqliteImageStore(database: dbB, root: Directory('${dir.path}/blobs'));
    final first = NewsImageCacheKey(path: 'first', version: '1');
    final second = NewsImageCacheKey(path: 'second', version: '1');
    final firstTicket = await a.capture(first);
    final secondTicket = await b.capture(second);
    expect(await a.put(second, Uint8List.fromList([7]), firstTicket), isFalse);
    final otherVersion = NewsImageCacheKey(path: first.path, version: '2');
    expect(await a.put(otherVersion, Uint8List.fromList([7]), firstTicket), isFalse);
    final otherRoot = NewsSqliteImageStore(database: dbB, root: Directory('${dir.path}/other'));
    await otherRoot.capture(first);
    expect(await otherRoot.put(first, Uint8List.fromList([7]), firstTicket), isFalse);
    expect(await Future.wait([
      a.put(first, Uint8List.fromList([1]), firstTicket),
      b.put(second, Uint8List.fromList([2]), secondTicket),
    ]), [true, true]);
    expect(await a.read(first), [1]);
    expect(await b.read(second), [2]);
    final stale = await a.capture(first);
    await b.invalidate(first.path);
    expect(await a.put(first, Uint8List.fromList([3]), stale), isFalse);
    expect(await b.read(first), isNull);
    expect(await b.read(second), [2]);
    final staleAll = await a.capture(second);
    await b.invalidate();
    expect(await a.put(second, Uint8List.fromList([4]), staleAll), isFalse);
  });

  test('failed publication preserves old index and corrupted blob is rejected', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-failure-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
    addTearDown(() async { await db.close(); await dir.delete(recursive: true); });
    final store = NewsSqliteImageStore(database: db, root: Directory('${dir.path}/blobs'));
    final key = NewsImageCacheKey(path: 'image', version: '1');
    expect(await store.put(key, Uint8List.fromList([1]), await store.capture(key)), isTrue);
    await db.execute("CREATE TRIGGER reject_news BEFORE INSERT ON news_store_images BEGIN SELECT RAISE(ABORT,'synthetic'); END");
    await expectLater(store.put(key, Uint8List.fromList([2]), await store.capture(key)), throwsA(anything));
    expect(await store.read(key), [1]);
    final row = (await db.query('news_store_images')).single;
    await File('${dir.path}/blobs/${row['filename']}').writeAsBytes([9]);
    expect(await store.read(key), isNull);
  });

  test('lost coordination database does not recreate cleared state', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-lost-db-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
    final root = Directory('${dir.path}/blobs');
    final store = NewsSqliteImageStore(database: db, root: root);
    final key = NewsImageCacheKey(path: 'image', version: '1');
    await store.put(key, Uint8List.fromList([1]), await store.capture(key));
    await store.invalidate();
    await db.close();
    final replaced = await databaseFactoryFfi.openDatabase('${dir.path}/replacement.db');
    addTearDown(() async { await replaced.close(); await dir.delete(recursive: true); });
    final afterLoss = NewsSqliteImageStore(database: replaced, root: root);
    await expectLater(afterLoss.read(key), throwsStateError);
    await expectLater(afterLoss.capture(key), throwsStateError);
  });

  test('corrupt coordination database does not expose old bytes', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-corrupt-db-');
    final dbFile = File('${dir.path}/store.db');
    final db = await databaseFactoryFfi.openDatabase(dbFile.path);
    final root = Directory('${dir.path}/blobs');
    final store = NewsSqliteImageStore(database: db, root: root);
    final key = NewsImageCacheKey(path: 'image', version: '1');
    await store.put(key, Uint8List.fromList([1]), await store.capture(key));
    await store.invalidate();
    await db.close();
    await dbFile.writeAsBytes([0, 1, 2, 3], flush: true);
    await expectLater(() async {
      final corrupted = await databaseFactoryFfi.openDatabase(dbFile.path);
      try { await NewsSqliteImageStore(database: corrupted, root: root).read(key); }
      finally { await corrupted.close(); }
    }, throwsA(anything));
    await dir.delete(recursive: true);
  });

  test('independent isolates publish without losing either index entry', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-isolates-');
    try {
      await Future.wait([
        Isolate.run(() => _writeIsolated(dir.path, 'first', 1)),
        Isolate.run(() => _writeIsolated(dir.path, 'second', 2)),
      ]);
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
      try {
        final store = NewsSqliteImageStore(database: db, root: Directory('${dir.path}/blobs'));
        expect(await store.read(NewsImageCacheKey(path: 'first', version: '1')), [1]);
        expect(await store.read(NewsImageCacheKey(path: 'second', version: '1')), [2]);
      } finally { await db.close(); }
    } finally {
      try { await dir.delete(recursive: true); } on FileSystemException { /* Isolate SQLite worker may still close. */ }
    }
  });

  test('missing epoch table after invalidation cannot revive a stale ticket', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-missing-epoch-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
    addTearDown(() async { await db.close(); await dir.delete(recursive: true); });
    final store = NewsSqliteImageStore(database: db, root: Directory('${dir.path}/blobs'));
    final key = NewsImageCacheKey(path: 'image', version: '1');
    final stale = await store.capture(key);
    await store.invalidate(key.path);
    await db.execute('DROP TABLE news_store_epochs');
    await expectLater(store.put(key, Uint8List.fromList([1]), stale), throwsStateError);
    final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE name='news_store_epochs'");
    expect(tables, isEmpty);
  });

  test('caller mutation during publication cannot alter stored bytes or hash', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-mutable-');
    final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
    addTearDown(() async { await db.close(); await dir.delete(recursive: true); });
    final store = NewsSqliteImageStore(database: db, root: Directory('${dir.path}/blobs'));
    final key = NewsImageCacheKey(path: 'image', version: '1');
    final bytes = Uint8List.fromList([1, 2, 3]);
    store.debugAfterBlobRename = () async { bytes[0] = 9; };
    expect(await store.put(key, bytes, await store.capture(key)), isTrue);
    expect(await store.read(key), [1, 2, 3]);
  });

  test('process crash before and after SQLite commit preserves a complete version', () async {
    for (final phase in ['before', 'after']) {
      final dir = await Directory.systemTemp.createTemp('news-store-crash-');
      try {
        final child = await Process.start('flutter',
            ['test', '--no-pub', 'test/support/news_sqlite_crash_fixture.dart'],
            environment: {'SYNTHETIC_NEWS_SQLITE_ROOT': dir.path, 'SYNTHETIC_NEWS_SQLITE_PHASE': phase},
            includeParentEnvironment: true, runInShell: Platform.isWindows);
        final out = child.stdout.transform(utf8.decoder).join();
        final err = child.stderr.transform(utf8.decoder).join();
        int code;
        try { code = await child.exitCode.timeout(const Duration(seconds: 90)); }
        on TimeoutException { child.kill(); await child.exitCode; rethrow; }
        expect(code, isNot(0));
        expect('${await out}${await err}', contains('SYNTHETIC_SQLITE_NEWS_CRASH'));
        final db = await databaseFactoryFfi.openDatabase('${dir.path}/store.db');
        try {
          final store = NewsSqliteImageStore(database: db, root: Directory('${dir.path}/blobs'));
          expect(await store.read(NewsImageCacheKey(path: 'image', version: '1')),
              phase == 'before' ? [1] : [2]);
        } finally { await db.close(); }
      } finally { await dir.delete(recursive: true); }
    }
  });
}
