import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/durable_optional_media_reservations.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('real writer publication invalidates an older scan', () async {
    final root = await Directory.systemTemp.createTemp('writer-reservation-');
    final dbA = await databaseFactoryFfi.openDatabase('${root.path}/quota.db', options: OpenDatabaseOptions(singleInstance: false));
    final dbB = await databaseFactoryFfi.openDatabase('${root.path}/quota.db', options: OpenDatabaseOptions(singleInstance: false));
    final store = await NewsSqliteImageStore.openOwned(databasePath: '${root.path}/index.db', root: Directory('${root.path}/blobs'), factory: databaseFactoryFfi);
    try {
      await DurableOptionalMediaReservations.createSchema(dbA);
      final a = DurableOptionalMediaReservations(dbA), b = DurableOptionalMediaReservations(dbB);
      final old = (await a.captureRevision('news'))!;
      final bRevision = (await b.captureRevision('news'))!;
      final key = NewsImageCacheKey(path: 'actual', version: '1');
      final ticket = await store.capture(key);
      final hold = (await b.reserveIfRevision(namespace: 'news', observation: bRevision,
          measuredBytes: 0, bytes: 1, limitBytes: 10))!;
      expect(await store.put(key, Uint8List.fromList([5]), ticket), isTrue);
      expect(await store.read(key), [5]);
      expect(await b.releaseGuarded(hold, 'news'), isTrue);
      expect(await a.reserveIfRevision(namespace: 'news', observation: old,
          measuredBytes: 0, bytes: 1, limitBytes: 10), isNull);
    } finally {
      await store.database.close(); await dbA.close(); await dbB.close();
      await root.delete(recursive: true);
    }
  });

  test('timeout never releases while actual filesystem write is pending', () async {
    final root = await Directory.systemTemp.createTemp('writer-reservation-timeout-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/quota.db');
    final store = await NewsSqliteImageStore.openOwned(databasePath: '${root.path}/index.db', root: Directory('${root.path}/blobs'), factory: databaseFactoryFfi);
    try {
      await DurableOptionalMediaReservations.createSchema(db);
      final coordinator = DurableOptionalMediaReservations(db);
      final observation = (await coordinator.captureRevision('news'))!;
      final key = NewsImageCacheKey(path: 'pending', version: '1');
      final ticket = await store.capture(key);
      expect(await coordinator.reserveIfRevision(namespace: 'news', observation: observation,
          measuredBytes: 0, bytes: 1, limitBytes: 10), isNotNull);
      final entered = Completer<void>(), proceed = Completer<void>();
      store.debugAfterBlobRename = () async { entered.complete(); await proceed.future; };
      final write = store.put(key, Uint8List.fromList([7]), ticket);
      await entered.future;
      await expectLater(write.timeout(const Duration(milliseconds: 20)), throwsA(isA<TimeoutException>()));
      expect(await db.query('optional_media_reservations'), hasLength(1));
      proceed.complete();
      expect(await write, isTrue);
      expect(await db.query('optional_media_reservations'), hasLength(1));
    } finally { await store.database.close(); await db.close(); await root.delete(recursive: true); }
  });

  test('invalidated writer ticket leaves its hold in place', () async {
    final root = await Directory.systemTemp.createTemp('writer-reservation-invalid-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/quota.db');
    final store = await NewsSqliteImageStore.openOwned(databasePath: '${root.path}/index.db', root: Directory('${root.path}/blobs'), factory: databaseFactoryFfi);
    try {
      await DurableOptionalMediaReservations.createSchema(db);
      final coordinator = DurableOptionalMediaReservations(db);
      final observation = (await coordinator.captureRevision('news'))!;
      final key = NewsImageCacheKey(path: 'invalid', version: '1');
      final ticket = await store.capture(key);
      expect(await coordinator.reserveIfRevision(namespace: 'news', observation: observation,
          measuredBytes: 0, bytes: 1, limitBytes: 10), isNotNull);
      await store.invalidate(key.path);
      expect(await store.put(key, Uint8List.fromList([7]), ticket), isFalse);
      expect(await db.query('optional_media_reservations'), hasLength(1));
    } finally { await store.database.close(); await db.close(); await root.delete(recursive: true); }
  });

  test('a pending writer hold blocks a second writer before any second blob', () async {
    final root = await Directory.systemTemp.createTemp('writer-reservation-pair-');
    final aDb = await databaseFactoryFfi.openDatabase('${root.path}/quota.db', options: OpenDatabaseOptions(singleInstance: false));
    final bDb = await databaseFactoryFfi.openDatabase('${root.path}/quota.db', options: OpenDatabaseOptions(singleInstance: false));
    final aStore = await NewsSqliteImageStore.openOwned(databasePath: '${root.path}/index.db', root: Directory('${root.path}/blobs'), factory: databaseFactoryFfi);
    final bStore = await NewsSqliteImageStore.openOwned(databasePath: '${root.path}/index.db', root: Directory('${root.path}/blobs'), factory: databaseFactoryFfi);
    try {
      await DurableOptionalMediaReservations.createSchema(aDb);
      final a = DurableOptionalMediaReservations(aDb), b = DurableOptionalMediaReservations(bDb);
      final first = NewsImageCacheKey(path: 'first', version: '1');
      final second = NewsImageCacheKey(path: 'second', version: '1');
      final firstTicket = await aStore.capture(first);
      await bStore.capture(second);
      final aRevision = (await a.captureRevision('news'))!;
      final bRevision = (await b.captureRevision('news'))!;
      final hold = (await a.reserveIfRevision(namespace: 'news', observation: aRevision,
          measuredBytes: 0, bytes: 1, limitBytes: 1))!;
      final entered = Completer<void>(), proceed = Completer<void>();
      aStore.debugAfterBlobRename = () async { entered.complete(); await proceed.future; };
      final write = aStore.put(first, Uint8List.fromList([1]), firstTicket);
      await entered.future;
      expect(await b.reserveIfRevision(namespace: 'news', observation: bRevision,
          measuredBytes: 0, bytes: 1, limitBytes: 1), isNull);
      proceed.complete();
      expect(await write, isTrue);
      expect(await a.releaseGuarded(hold, 'news'), isTrue);
      expect(await bStore.read(second), isNull);
    } finally {
      await aStore.database.close(); await bStore.database.close();
      await aDb.close(); await bDb.close(); await root.delete(recursive: true);
    }
  });

  test('abrupt exit after hold or actual put retains reservation', () async {
    for (final phase in ['hold', 'put']) {
      final root = await Directory.systemTemp.createTemp('writer-reservation-exit-');
      try {
        final child = await Process.start('flutter', ['test', '--no-pub', 'test/support/news_writer_hold_fixture.dart'],
            environment: {'SYNTHETIC_NEWS_HOLD_ROOT': root.path, 'SYNTHETIC_NEWS_HOLD_PHASE': phase},
            includeParentEnvironment: true, runInShell: Platform.isWindows);
        final out = child.stdout.transform(utf8.decoder).join();
        final err = child.stderr.transform(utf8.decoder).join();
        int code;
        try { code = await child.exitCode.timeout(const Duration(seconds: 90)); }
        on TimeoutException { child.kill(); await child.exitCode; rethrow; }
        expect(code, isNot(0));
        expect('${await out}${await err}', contains('SYNTHETIC_NEWS_HOLD_EXIT'));
        final db = await databaseFactoryFfi.openDatabase('${root.path}/quota.db');
        try { expect(await db.query('optional_media_reservations'), hasLength(1)); }
        finally { await db.close(); }
        if (phase == 'put') {
          final store = await NewsSqliteImageStore.openOwned(databasePath: '${root.path}/index.db', root: Directory('${root.path}/blobs'), factory: databaseFactoryFfi);
          try { expect(await store.read(NewsImageCacheKey(path: 'image', version: '1')), [5]); }
          finally { await store.database.close(); }
        } else {
          expect(await Directory('${root.path}/blobs').exists(), isFalse);
        }
      } finally { await root.delete(recursive: true); }
    }
  });
}
