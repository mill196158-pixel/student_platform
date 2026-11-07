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
}
