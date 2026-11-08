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
  final store = await NewsSqliteImageStore.openOwned(databasePath: '$root/store.db',
      root: Directory('$root/blobs'), factory: databaseFactoryFfi);
  final db = store.database;
  try {
    final key = NewsImageCacheKey(path: path, version: '1');
    if (!await store.put(key, Uint8List.fromList([value]), await store.capture(key))) {
      throw StateError('Synthetic publication rejected');
    }
  } finally { await db.close(); }
}

Future<void> _holdDatabaseLock(List<Object> args) async {
  final dbPath = args[0] as String, port = args[1] as SendPort;
  final writeLock = args[2] as bool;
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(dbPath, options: OpenDatabaseOptions(singleInstance: false));
  final release = ReceivePort();
  try {
    await db.execute(writeLock ? 'BEGIN IMMEDIATE' : 'BEGIN');
    await db.rawQuery('SELECT * FROM news_store_images');
    port.send(release.sendPort);
    await release.first;
    await db.execute('COMMIT');
    port.send('released');
  } finally { release.close(); await db.close(); }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('two handles preserve both publications and stale tickets are rejected', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-');
    final a = await NewsSqliteImageStore.openOwned(databasePath: '${dir.path}/store.db', root: Directory('${dir.path}/blobs'), factory: databaseFactoryFfi);
    final b = await NewsSqliteImageStore.openOwned(databasePath: '${dir.path}/store.db', root: Directory('${dir.path}/blobs'), factory: databaseFactoryFfi);
    final dbA = a.database, dbB = b.database;
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
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

  test('same-worker reader contention fails closed without replaying write', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-commit-lock-');
    final store = await NewsSqliteImageStore.openOwned(databasePath: '${dir.path}/store.db',
        root: Directory('${dir.path}/blobs'), factory: databaseFactoryFfi);
    final dbA = store.database;
    final dbB = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
    await dbA.rawQuery('PRAGMA journal_mode=DELETE');
    final key = NewsImageCacheKey(path: 'image', version: '1');
    expect(await store.put(key, Uint8List.fromList([8]), await store.capture(key)), isTrue);
    final ticket = await store.capture(key);
    await dbB.execute('BEGIN');
    await dbB.rawQuery('SELECT * FROM news_store_images');
    var writes = 0;
    store.debugAfterBlobRename = () async { writes++; };
    final pending = store.put(key, Uint8List.fromList([1]), ticket)
        .then((value) => value, onError: (Object _) => false);
    expect(await pending.timeout(const Duration(seconds: 2)), isFalse);
    await dbB.execute('COMMIT');
    await store.waitForOwnedClose().timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(writes, 1);
    List<Map<String, Object?>>? rows;
    for (var i = 0; i < 40 && rows == null; i++) {
      try { rows = await dbB.query('news_store_images', where: 'id=?', whereArgs: [key.id]); }
      catch (_) { await Future<void>.delayed(const Duration(milliseconds: 50)); }
    }
    expect(rows, isNotNull, reason: 'late cancelled BEGIN must eventually roll back');
    expect(rows, hasLength(1));
    expect(await File('${dir.path}/blobs/${rows!.single['filename']}').readAsBytes(), [8]);
  });

  test('busy timeout is connection-specific on the dedicated database', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-pragma-');
    final store = await NewsSqliteImageStore.openOwned(databasePath: '${dir.path}/store.db', root: Directory('${dir.path}/blobs'), factory: databaseFactoryFfi);
    final dbA = store.database;
    final dbB = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
    await dbB.rawQuery('PRAGMA busy_timeout=4321');
    await store.capture(NewsImageCacheKey(path: 'image', version: '1'));
    expect((await dbB.rawQuery('PRAGMA busy_timeout')).single.values.single, 4321);
    expect((await dbA.rawQuery('PRAGMA busy_timeout')).single.values.single, 100);
  });

  test('ambiguous commit poisons injected shared handle without closing it', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-injected-');
    final dbA = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    final dbB = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
    await dbA.rawQuery('PRAGMA journal_mode=DELETE');
    await dbA.rawQuery('PRAGMA busy_timeout=10');
    final store = NewsSqliteImageStore(database: dbA, root: Directory('${dir.path}/blobs'));
    final key = NewsImageCacheKey(path: 'image', version: '1');
    final ticket = await store.capture(key);
    expect((await dbA.rawQuery('PRAGMA busy_timeout')).single.values.single, 10);
    await dbB.execute('BEGIN');
    await dbB.rawQuery('SELECT * FROM news_store_images');
    final result = store.put(key, Uint8List.fromList([1]), ticket).then((v) => v, onError: (Object _) => false);
    expect(await result.timeout(const Duration(seconds: 2)), isFalse);
    expect(store.usable, isFalse);
    expect(dbA.isOpen, isTrue);
    await expectLater(store.read(key), throwsStateError);
    await dbB.execute('COMMIT');
  });

  test('independent reader worker can release a brief commit lock', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-isolate-lock-');
    final store = await NewsSqliteImageStore.openOwned(databasePath: '${dir.path}/store.db', root: Directory('${dir.path}/blobs'), factory: databaseFactoryFfi);
    final db = store.database;
    final port = ReceivePort();
    Isolate? holder;
    SendPort? control;
    try {
      await db.rawQuery('PRAGMA journal_mode=DELETE');
      final key = NewsImageCacheKey(path: 'image', version: '1');
      final ticket = await store.capture(key);
      final ready = Completer<SendPort>(), done = Completer<void>();
      port.listen((message) { if (message is SendPort) { ready.complete(message); } else if (message == 'released') { done.complete(); } });
      holder = await Isolate.spawn(_holdDatabaseLock, [db.path, port.sendPort, false]);
      control = await ready.future.timeout(const Duration(seconds: 5));
      var writes = 0;
      store.debugAfterBlobRename = () async { writes++; control!.send(true); };
      expect(await store.put(key, Uint8List.fromList([1]), ticket), isTrue);
      await done.future.timeout(const Duration(seconds: 5));
      expect(writes, 1);
      expect(await store.read(key), [1]);
    } finally { control?.send(true); holder?.kill(priority: Isolate.immediate); port.close(); await db.close(); try { await dir.delete(recursive: true); } on FileSystemException {} }
  });

  test('long-held writer lock has bounded acquisition without executing write', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-long-lock-');
    final store = await NewsSqliteImageStore.openOwned(databasePath: '${dir.path}/store.db', root: Directory('${dir.path}/blobs'), factory: databaseFactoryFfi);
    final db = store.database;
    final port = ReceivePort();
    Isolate? holder;
    SendPort? control;
    try {
      final key = NewsImageCacheKey(path: 'image', version: '1');
      final ticket = await store.capture(key);
      final ready = Completer<SendPort>(), done = Completer<void>();
      port.listen((message) { if (message is SendPort) { ready.complete(message); } else if (message == 'released') { done.complete(); } });
      holder = await Isolate.spawn(_holdDatabaseLock, [db.path, port.sendPort, true]);
      control = await ready.future.timeout(const Duration(seconds: 5));
      var writes = 0;
      store.debugAfterBlobRename = () async { writes++; };
      final watch = Stopwatch()..start();
      await expectLater(store.put(key, Uint8List.fromList([1]), ticket), throwsA(anything));
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(writes, 0);
      control.send(true); await done.future.timeout(const Duration(seconds: 5));
    } finally { control?.send(true); holder?.kill(priority: Isolate.immediate); port.close(); await db.close(); try { await dir.delete(recursive: true); } on FileSystemException {} }
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
    await expectLater(store.read(key), throwsStateError);
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

  test('legacy keep-version, path invalidation and global clear are durable', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-suppression-');
    final dbA = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    final dbB = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
    final a = NewsSqliteImageStore(database: dbA, root: Directory('${dir.path}/blobs'));
    final b = NewsSqliteImageStore(database: dbB, root: Directory('${dir.path}/blobs'));
    final old = NewsImageCacheKey(path: 'image', version: '1');
    final current = NewsImageCacheKey(path: 'image', version: '2');
    Future<Uint8List?> legacy() async => Uint8List.fromList([4]);
    final stale = await a.capture(old);
    final fresh = await b.capture(current);
    expect(await a.pruneOtherVersions(old, stale), isFalse);
    expect(await b.pruneOtherVersions(current, fresh), isTrue);
    expect((await a.readWithLegacy(old, legacy)).state, NewsImageReadState.miss);
    expect((await a.readWithLegacy(current, legacy)).state, NewsImageReadState.hit);
    await b.invalidate(current.path);
    expect((await a.readWithLegacy(current, legacy)).state, NewsImageReadState.miss);
    await b.invalidate();
    final afterClear = await a.capture(current);
    expect(await a.pruneOtherVersions(current, afterClear), isTrue);
    expect((await b.readWithLegacy(current, legacy)).state, NewsImageReadState.miss);
    await dbB.execute('DROP TABLE news_store_suppression');
    var calls = 0;
    final unknown = await a.readWithLegacy(current, () async { calls++; return Uint8List.fromList([4]); });
    expect(unknown.state, NewsImageReadState.unknown);
    expect(calls, 0);
  });

  test('legacy read and invalidation serialize across handles', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-legacy-race-');
    final dbA = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    final dbB = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
    final a = NewsSqliteImageStore(database: dbA, root: Directory('${dir.path}/blobs'));
    final b = NewsSqliteImageStore(database: dbB, root: Directory('${dir.path}/blobs'));
    final key = NewsImageCacheKey(path: 'image', version: '1');
    final entered = Completer<void>(), release = Completer<void>();
    final reading = a.readWithLegacy(key, () async { entered.complete(); await release.future; return Uint8List.fromList([1]); });
    await entered.future;
    final clearing = b.invalidate(key.path);
    release.complete();
    expect((await reading).state, NewsImageReadState.hit);
    await clearing;
    expect((await a.readWithLegacy(key, () async => Uint8List.fromList([1]))).state, NewsImageReadState.miss);
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

  test('cancelled late capture cannot invalidate a newer ticket', () async {
    final dir = await Directory.systemTemp.createTemp('news-store-cancel-ticket-');
    final dbA = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    final dbB = await databaseFactoryFfi.openDatabase('${dir.path}/store.db', options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(() async { await dbA.close(); await dbB.close(); await dir.delete(recursive: true); });
    final a = NewsSqliteImageStore(database: dbA, root: Directory('${dir.path}/blobs'));
    final b = NewsSqliteImageStore(database: dbB, root: Directory('${dir.path}/blobs'));
    final key = NewsImageCacheKey(path: 'image', version: '1');
    final newer = await b.capture(key);
    var calls = 0;
    await expectLater(a.capture(key, current: () => ++calls < 3), throwsStateError);
    expect(calls, 3);
    expect(await b.isCurrent(key, newer), isTrue);
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
