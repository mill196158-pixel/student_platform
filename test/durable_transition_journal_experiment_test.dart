import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/durable_transition_journal_experiment.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('project epoch, rollback, restart and two-connection ABA stay closed', () async {
    if (Platform.isWindows) {
      open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('transition-journal-test-');
    final file = p.join(dir.path, 'journal.sqlite');
    Future<Database> connect() => databaseFactoryFfi.openDatabase(file,
        options: OpenDatabaseOptions(singleInstance: false, onConfigure: (db) async {
          await db.execute('PRAGMA busy_timeout=5000');
          await db.execute('PRAGMA journal_mode=WAL');
          await db.execute('PRAGMA synchronous=FULL');
        }));
    var db = await connect();
    Database? second;
    try {
      await DurableTransitionJournalExperiment.createForExperiment(db);
      var journal = DurableTransitionJournalExperiment(db);
      const project = 'https://example.invalid';
      Future<Map<String, Object?>> row(Database connection) async =>
          (await connection.query('transition_experiment', where: 'project = ?', whereArgs: [project])).single;
      final oldA = (await journal.begin(project: project, uid: 'A', sid: 'sid-A', isCurrent: () => true))!;
      expect((await row(db))['state'], 'pending');
      await db.close();
      db = await connect();
      journal = DurableTransitionJournalExperiment(db);
      final afterRestart = await row(db);
      expect(afterRestart['state'], 'pending');
      expect(afterRestart['snapshot'], isNull);
      // A separate SQLite writer is terminated while its prepared update is
      // uncommitted. Reopen must still see the prior pending record.
      await db.close();
      final child = await Process.start('python', ['-u', '-c',
        'import sqlite3,sys\n'
        'db=sqlite3.connect(sys.argv[1])\n'
        'db.execute("PRAGMA synchronous=FULL")\n'
        'db.execute("BEGIN IMMEDIATE")\n'
        'db.execute("UPDATE transition_experiment SET state=?,snapshot=?",("prepared",b"partial"))\n'
        'print("ready",flush=True)\n'
        'sys.stdin.read()\n', file]);
      try {
        expect(await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first
            .timeout(const Duration(seconds: 10)), 'ready');
      } finally {
        child.kill();
        await child.exitCode.timeout(const Duration(seconds: 10));
      }
      db = await connect();
      journal = DurableTransitionJournalExperiment(db);
      expect((await row(db))['state'], 'pending');
      expect((await row(db))['snapshot'], isNull);
      second = await connect();
      final other = DurableTransitionJournalExperiment(second);
      final b = (await other.begin(project: project, uid: 'B', sid: 'sid-B', isCurrent: () => true))!;
      final a = (await journal.begin(project: project, uid: 'A', sid: 'sid-A', isCurrent: () => true))!;
      expect(a.epoch, greaterThan(b.epoch));
      expect(b.epoch, greaterThan(oldA.epoch));
      expect(await other.prepare(b, Uint8List.fromList([8]), isCurrent: () => true), isFalse);
      expect(await other.revoke(b, isCurrent: () => true), isFalse);
      final entered = Completer<void>(), release = Completer<void>();
      var stillCurrent = true;
      journal.debugBeforePrepareReturn = () async { entered.complete(); await release.future; };
      final interrupted = journal.prepare(a, Uint8List.fromList([1, 2, 3]),
          isCurrent: () => stillCurrent);
      await entered.future;
      expect((await row(second))['state'], 'pending', reason: 'uncommitted snapshot is not visible');
      stillCurrent = false;
      release.complete();
      expect(await interrupted, isFalse);
      expect((await row(db))['state'], 'pending');
      expect((await row(db))['snapshot'], isNull);
      journal.debugBeforePrepareReturn = null;
      expect(await journal.prepare(a, Uint8List.fromList([1, 2, 3]), isCurrent: () => true), isTrue);
      final prepared = await row(second);
      expect(prepared['state'], 'prepared');
      expect(prepared['snapshot'], [1, 2, 3]);
      expect(await journal.revoke(a, isCurrent: () => true), isTrue);
      expect((await row(second))['state'], 'revoked');
      expect((await row(second))['snapshot'], isNull);
      expect(await journal.prepare(a, Uint8List.fromList([7]), isCurrent: () => true), isFalse);
      final first = (await journal.begin(project: project, uid: 'A', sid: 'sid-A', isCurrent: () => true))!;
      final writerEntered = Completer<void>(), writerRelease = Completer<void>();
      journal.debugBeforePrepareReturn = () async { writerEntered.complete(); await writerRelease.future; };
      final preparing = journal.prepare(first, Uint8List.fromList([4]), isCurrent: () => true);
      await writerEntered.future;
      var secondFinished = false;
      final competing = other.begin(project: project, uid: 'B', sid: 'sid-B', isCurrent: () => true)
          .whenComplete(() => secondFinished = true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(secondFinished, isFalse, reason: 'second writer waits for the first transaction');
      writerRelease.complete();
      expect(await preparing, isTrue);
      final next = await competing;
      // The FFI worker can time out under contention. It must fail closed;
      // a fresh attempt after the first commit may then proceed.
      if (next == null) {
        expect((await row(second))['state'], 'prepared');
        expect((await row(second))['snapshot'], [4]);
      }
      final accepted = next ?? await other.begin(project: project, uid: 'B',
          sid: 'sid-B', isCurrent: () => true);
      expect(accepted, isNotNull);
      expect(accepted!.epoch, first.epoch + 1);
      expect((await row(second))['state'], 'pending');
      expect((await row(second))['snapshot'], isNull);
      expect(await other.revoke(accepted, isCurrent: () => true), isTrue);
      await second.close();
      second = null;
      await db.close();
      db = await connect();
      expect((await row(db))['state'], 'revoked');
      expect((await row(db))['snapshot'], isNull);
    } finally {
      await second?.close();
      await db.close();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final resolved = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, resolved) || !p.basename(resolved).startsWith('transition-journal-test-')) {
        throw StateError('Unsafe synthetic cleanup target');
      }
      await dir.delete(recursive: true);
    }
  });
}
