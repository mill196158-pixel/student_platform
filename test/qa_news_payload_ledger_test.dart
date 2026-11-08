import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

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
    final a = (await QaNewsPayloadLedger.create(aDb, 'ns', 'epoch-a'))!;
    final b = (await QaNewsPayloadLedger.openExisting(bDb, 'ns', 'epoch-b'))!;
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
    final initial = (await QaNewsPayloadLedger.create(db, 'ns', 'old'))!;
    expect(await initial.reserve(8, 10), isNotNull);
    await db.close();
    db = await databaseFactoryFfi.openDatabase(path);
    final reopened = (await QaNewsPayloadLedger.openExisting(db, 'ns', 'new'))!;
    expect(await reopened.reserve(3, 10), isNull);
    await db.close();
    await root.delete(recursive: true);
  });

  test('separate isolates cannot both reserve beyond the shared budget', () async {
    final root = await Directory.systemTemp.createTemp('qa-news-isolates-');
    final path = '${root.path}/ledger.db';
    final db = await databaseFactoryFfi.openDatabase(path);
    expect(await QaNewsPayloadLedger.create(db, 'ns', 'epoch'), isNotNull);
    await db.close();
    Future<bool> attempt() => Isolate.run(() async {
      sqfliteFfiInit();
      final local = await databaseFactoryFfi.openDatabase(path,
          options: OpenDatabaseOptions(singleInstance: false));
      try {
        final ledger = await QaNewsPayloadLedger.openExisting(local, 'ns', 'epoch');
        return await ledger?.reserve(6, 10) != null;
      } finally {
        await local.close();
      }
    });
    try {
      final accepted = await Future.wait([attempt(), attempt()]);
      expect(accepted.where((value) => value), hasLength(1));
      final verify = await databaseFactoryFfi.openDatabase(path);
      try {
        final ledger = (await QaNewsPayloadLedger.openExisting(verify, 'ns', 'epoch'))!;
        expect(await ledger.reserve(5, 10), isNull);
      } finally {
        await verify.close();
      }
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('foreign incarnation rejects copied token and invalid schema fails closed', () async {
    final root = await Directory.systemTemp.createTemp('qa-news-issuer-');
    final aDb = await databaseFactoryFfi.openDatabase('${root.path}/a.db');
    final bDb = await databaseFactoryFfi.openDatabase('${root.path}/b.db');
    try {
      final a = (await QaNewsPayloadLedger.create(aDb, 'ns', 'epoch'))!;
      final b = (await QaNewsPayloadLedger.create(bDb, 'ns', 'epoch'))!;
      final ticket = (await a.reserve(4, 10))!;
      final row = (await aDb.query('qa_news_payload_ledger')).single;
      await bDb.insert('qa_news_payload_ledger', row);
      expect(await b.publish(ticket), isFalse);
      expect((await bDb.query('qa_news_payload_ledger')).single['state'], 'held');
      expect(await QaNewsPayloadLedger.create(aDb, 'ns', 'epoch'), isNull);
      await aDb.execute('DROP TABLE qa_news_payload_ledger');
      expect(await a.publish(ticket), isFalse);
      expect(await QaNewsPayloadLedger.openExisting(aDb, 'ns', 'epoch'), isNull);
      expect(await QaNewsPayloadLedger.create(aDb, 'ns', 'epoch'), isNull);
    } finally {
      await aDb.close();
      await bDb.close();
      await root.delete(recursive: true);
    }
  });

  test('sqliteX objects are not mistaken for internal SQLite schema', () async {
    final root = await Directory.systemTemp.createTemp('qa-news-schema-');
    final empty = await databaseFactoryFfi.openDatabase('${root.path}/other.db');
    final db = await databaseFactoryFfi.openDatabase('${root.path}/ledger.db');
    try {
      await empty.execute('CREATE TABLE sqliteXunrelated (id INTEGER)');
      expect(await QaNewsPayloadLedger.create(empty, 'ns', 'epoch'), isNull);
      final ledger = (await QaNewsPayloadLedger.create(db, 'ns', 'epoch'))!;
      final ticket = (await ledger.reserve(1, 10))!;
      await db.execute('CREATE TABLE sqliteXunrelated (id INTEGER)');
      expect(await QaNewsPayloadLedger.openExisting(db, 'ns', 'epoch'), isNull);
      expect(await ledger.publish(ticket), isFalse);
      expect(await ledger.reserve(1, 10), isNull);
      await db.execute('DROP TABLE sqliteXunrelated');
      await db.execute('CREATE TRIGGER sqliteXtrigger AFTER INSERT ON qa_news_payload_ledger BEGIN SELECT 1; END');
      expect(await QaNewsPayloadLedger.openExisting(db, 'ns', 'epoch'), isNull);
      expect(await ledger.releaseUnwritten(ticket), isFalse);
    } finally {
      await empty.close();
      await db.close();
      await root.delete(recursive: true);
    }
  });

  test('abrupt process termination retains held and published accounting', () async {
    for (final phase in ['held', 'published']) {
      final root = await Directory.systemTemp.createTemp('qa-news-process-');
      final path = '${root.path}/ledger.db';
      final db = await databaseFactoryFfi.openDatabase(path);
      expect(await QaNewsPayloadLedger.create(db, 'ns', 'epoch'), isNotNull);
      await db.close();
      try {
        final child = await Process.start('flutter',
            ['test', '--no-pub', 'test/support/qa_ledger_crash_fixture.dart'],
            environment: {'SYNTHETIC_QA_LEDGER_PATH': path, 'SYNTHETIC_QA_LEDGER_PHASE': phase},
            includeParentEnvironment: true, runInShell: Platform.isWindows);
        final out = child.stdout.transform(utf8.decoder).join();
        final err = child.stderr.transform(utf8.decoder).join();
        int code;
        try {
          code = await child.exitCode.timeout(const Duration(seconds: 90));
        } on TimeoutException {
          child.kill();
          await child.exitCode;
          rethrow;
        }
        expect(code, isNot(0));
        expect('${await out}${await err}', contains('SYNTHETIC_QA_LEDGER_TERMINATION'));
        final reopened = await databaseFactoryFfi.openDatabase(path);
        try {
          final ledger = (await QaNewsPayloadLedger.openExisting(reopened, 'ns', 'epoch'))!;
          expect(await ledger.reserve(3, 10), isNull);
          expect((await reopened.query('qa_news_payload_ledger')).single['state'], phase);
        } finally { await reopened.close(); }
      } finally { await root.delete(recursive: true); }
    }
  });
}
