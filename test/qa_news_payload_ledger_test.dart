import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/qa_news_payload_ledger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('two handles serialize holds and published bytes stay accounted', () async {
    final root = await Directory.systemTemp.createTemp('qa-news-ledger-');
    final path = '${root.path}/ledger.db';
    Future<Database> open() => databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final aDb = await open();
    final bDb = await open();
    addTearDown(() async {
      await aDb.close();
      await bDb.close();
      await root.delete(recursive: true);
    });
    await QaNewsPayloadLedger.createSchema(aDb);
    final a = QaNewsPayloadLedger(aDb, 'ns', 'epoch-a');
    final b = QaNewsPayloadLedger(bDb, 'ns', 'epoch-b');
    final ticket = await a.reserve(6, 10);
    expect(ticket, isNotNull);
    expect(await b.reserve(5, 10), isNull);
    expect(await b.publish(ticket!), isFalse);
    expect(await a.publish(ticket), isTrue);
    expect(await a.publish(ticket), isFalse);
    expect(await a.releaseUnwritten(ticket), isFalse);
    expect(await b.reserve(5, 10), isNull);
    final other = await b.reserve(4, 10);
    expect(other, isNotNull);
    expect(await b.releaseUnwritten(other!), isTrue);
    expect(await b.releaseUnwritten(other), isFalse);
    expect(await b.reserve(4, 10), isNotNull);
  });

  test('abandoned hold survives database reopen and fails closed', () async {
    final root = await Directory.systemTemp.createTemp('qa-news-restart-');
    final path = '${root.path}/ledger.db';
    var db = await databaseFactoryFfi.openDatabase(path);
    await QaNewsPayloadLedger.createSchema(db);
    expect(await QaNewsPayloadLedger(db, 'ns', 'old').reserve(8, 10), isNotNull);
    await db.close();
    db = await databaseFactoryFfi.openDatabase(path);
    expect(await QaNewsPayloadLedger(db, 'ns', 'new').reserve(3, 10), isNull);
    await db.close();
    await root.delete(recursive: true);
  });
}
