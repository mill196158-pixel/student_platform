import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/durable_optional_media_reservations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('separate connections serialize reservations and retain crash holds', () async {
    final root = await Directory.systemTemp.createTemp('durable-reserve-');
    final path = '${root.path}/reservation.db';
    Future<Database> open() => databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    var first = await open();
    final second = await open();
    await DurableOptionalMediaReservations.createSchema(first);
    var a = DurableOptionalMediaReservations(first);
    final b = DurableOptionalMediaReservations(second);
    final hold = await a.reserve(bytes: 6, limitBytes: 10, measure: () async => 0);
    expect(hold, isNotNull);
    expect(await b.reserve(bytes: 5, limitBytes: 10, measure: () async => 0), isNull);
    // An abandoned writer does not get its reservation released by restart.
    await first.close();
    first = await open();
    a = DurableOptionalMediaReservations(first);
    expect(await a.reserve(bytes: 5, limitBytes: 10, measure: () async => 0), isNull);
    expect(await a.releaseSettled('unknown'), isFalse);
    expect(await a.releaseSettled(hold!), isTrue);
    final next = await b.reserve(bytes: 5, limitBytes: 10, measure: () async => 0);
    expect(next, isNotNull);
    expect(await b.releaseSettled(next!), isTrue);
    await first.close();
    await second.close();
    await root.delete(recursive: true);
  });

  test('unknown, failing and competing measurements do not over-admit', () async {
    final root = await Directory.systemTemp.createTemp('durable-reserve-');
    final path = '${root.path}/reservation.db';
    final aDb = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final bDb = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    await DurableOptionalMediaReservations.createSchema(aDb);
    final a = DurableOptionalMediaReservations(aDb);
    final b = DurableOptionalMediaReservations(bDb);
    expect(await a.reserve(bytes: 1, limitBytes: 10, measure: () async => null), isNull);
    expect(await a.reserve(bytes: 1, limitBytes: 10,
        measure: () async => throw StateError('unavailable')), isNull);
    final entered = Completer<void>();
    final proceed = Completer<void>();
    final first = a.reserve(bytes: 6, limitBytes: 10, measure: () async {
      entered.complete();
      await proceed.future;
      return 0;
    });
    await entered.future;
    final concurrent = b.reserve(bytes: 6, limitBytes: 10, measure: () async => 0);
    proceed.complete();
    final token = await first;
    expect(token, isNotNull);
    expect(await concurrent, isNull); // Busy or observes the committed hold.
    expect(await b.reserve(bytes: 6, limitBytes: 10, measure: () async => 0), isNull);
    expect(await a.releaseSettled(token!), isTrue);
    expect(await b.reserve(bytes: 6, limitBytes: 10, measure: () async => 5), isNull);
    await aDb.close();
    await bDb.close();
    await root.delete(recursive: true);
  });

  test('SQLite busy fails closed; retry succeeds after lock releases', () async {
    final root = await Directory.systemTemp.createTemp('durable-reserve-busy-');
    final path = '${root.path}/reservation.db';
    final first = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final second = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    await DurableOptionalMediaReservations.createSchema(first);
    await second.execute('PRAGMA busy_timeout=0');
    final locked = Completer<void>();
    final release = Completer<void>();
    final transaction = first.transaction((txn) async {
      await txn.insert('optional_media_reservations', {'token': 'lock', 'bytes': 1});
      locked.complete();
      await release.future;
    });
    await locked.future;
    final b = DurableOptionalMediaReservations(second);
    expect(await b.reserve(bytes: 2, limitBytes: 10, measure: () async => 0), isNull);
    release.complete();
    await transaction;
    final token = await b.reserve(bytes: 2, limitBytes: 10, measure: () async => 0);
    expect(token, isNotNull);
    expect(await b.releaseSettled(token!), isTrue);
    await first.close();
    await second.close();
    await root.delete(recursive: true);
  });

  test('stale scan cannot admit after another writer settles', () async {
    final root = await Directory.systemTemp.createTemp('durable-reserve-revision-');
    final path = '${root.path}/db.sqlite';
    Future<Database> open() => databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final aDb = await open();
    final bDb = await open();
    try {
      await DurableOptionalMediaReservations.createSchema(aDb);
      final a = DurableOptionalMediaReservations(aDb);
      final b = DurableOptionalMediaReservations(bDb);
      final scannedBefore = (await a.captureRevision('news'))!;
      final bObservation = (await b.captureRevision('news'))!;
      final hold = (await b.reserveIfRevision(namespace: 'news', observation: bObservation,
          measuredBytes: 0, bytes: 6, limitBytes: 10))!;
      await File('${root.path}/published').writeAsBytes(List.filled(6, 1));
      expect(await b.releaseGuarded(hold, 'news'), isTrue);
      expect(await a.reserveIfRevision(namespace: 'news', observation: scannedBefore,
          measuredBytes: 0, bytes: 5, limitBytes: 10), isNull);
      final after = (await a.captureRevision('news'))!;
      expect(await a.reserveIfRevision(namespace: 'news', observation: after,
          measuredBytes: 6, bytes: 5, limitBytes: 10), isNull);
      expect(await a.reserveIfRevision(namespace: 'other', observation: after,
          measuredBytes: 6, bytes: 1, limitBytes: 10), isNull);
    } finally {
      await aDb.close();
      await bDb.close();
      await root.delete(recursive: true);
    }
  });

  test('foreign incarnation and malformed revision cannot release capacity', () async {
    final root = await Directory.systemTemp.createTemp('durable-reserve-foreign-');
    final aDb = await databaseFactoryFfi.openDatabase('${root.path}/a.db');
    final bDb = await databaseFactoryFfi.openDatabase('${root.path}/b.db');
    try {
      await DurableOptionalMediaReservations.createSchema(aDb);
      await DurableOptionalMediaReservations.createSchema(bDb);
      final a = DurableOptionalMediaReservations(aDb);
      final b = DurableOptionalMediaReservations(bDb);
      final foreign = (await a.captureRevision('news'))!;
      expect(await b.reserveIfRevision(namespace: 'news', observation: foreign,
          measuredBytes: 0, bytes: 1, limitBytes: 10), isNull);
      final own = (await b.captureRevision('news'))!;
      final hold = (await b.reserveIfRevision(namespace: 'news', observation: own,
          measuredBytes: 0, bytes: 2, limitBytes: 10))!;
      final copied = (await bDb.query('optional_media_reservations')).single;
      await aDb.insert('optional_media_reservations', copied);
      expect(await a.releaseGuarded(hold, 'news'), isFalse);
      expect(await b.releaseGuarded(hold, 'other'), isFalse);
      await bDb.execute('UPDATE optional_media_revision SET revision=9223372036854775807');
      expect(await b.captureRevision('news'), isNull);
      expect(await b.reserve(bytes: 1, limitBytes: 10, measure: () async => 0), isNull);
      expect(await b.reserveIfRevision(namespace: 'news', observation: own,
          measuredBytes: 0, bytes: 1, limitBytes: 10), isNull);
      expect(await b.releaseGuarded(hold, 'news'), isFalse);
      expect(await bDb.query('optional_media_reservations'), hasLength(1));
      await bDb.execute('DROP TABLE optional_media_revision');
      expect(await b.captureRevision('news'), isNull);
      expect(await b.releaseGuarded(hold, 'news'), isFalse);
      expect(await bDb.query('optional_media_reservations'), hasLength(1));
    } finally {
      await aDb.close();
      await bDb.close();
      await root.delete(recursive: true);
    }
  });

  test('unexpected trigger on coordinator tables fails closed', () async {
    final root = await Directory.systemTemp.createTemp('durable-reserve-trigger-');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/db.sqlite');
    try {
      await DurableOptionalMediaReservations.createSchema(db);
      final coordinator = DurableOptionalMediaReservations(db);
      final before = (await coordinator.captureRevision('news'))!;
      await db.execute('CREATE TRIGGER sqliteXtrigger AFTER INSERT ON optional_media_reservations BEGIN SELECT 1; END');
      expect(await coordinator.captureRevision('news'), isNull);
      expect(await coordinator.reserveIfRevision(namespace: 'news', observation: before,
          measuredBytes: 0, bytes: 1, limitBytes: 10), isNull);
      expect(await db.query('optional_media_reservations'), isEmpty);
    } finally { await db.close(); await root.delete(recursive: true); }
  });
}
