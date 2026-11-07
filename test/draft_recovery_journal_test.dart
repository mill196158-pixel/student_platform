import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/ui/learning/draft_recovery_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  sqfliteFfiInit();

  test('restart and A to B to A keep recovery private and bounded', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final journal = DraftRecoveryJournal(open: () async => db);
    var allowedA = true;
    for (var index = 0; index < DraftRecoveryJournal.maxOwnerEntries; index++) {
      expect(await journal.append(project: 'p', owner: 'a', sessionId: 's-a',
          conversation: 'chat', draft: {'text': 'edit $index', 'files': [], 'reply': null},
          permitted: () => allowedA), isTrue);
    }
    expect(await journal.append(project: 'p', owner: 'a', sessionId: 's-a',
        conversation: 'chat', draft: {'text': 'overflow'}, permitted: () => allowedA), isFalse);
    allowedA = false;
    final restarted = DraftRecoveryJournal(open: () async => db);
    expect(await restarted.pending(project: 'p', owner: 'b', conversation: 'chat',
        permitted: () => true), isEmpty);
    expect(await restarted.pending(project: 'p', owner: 'a', conversation: 'chat',
        permitted: () => allowedA), isEmpty);
    allowedA = true;
    final rows = await restarted.pending(project: 'p', owner: 'a', conversation: 'chat',
        permitted: () => allowedA);
    expect(rows, hasLength(DraftRecoveryJournal.maxOwnerEntries));
    expect(rows.first['draft'], containsPair('text', 'edit ${DraftRecoveryJournal.maxOwnerEntries - 1}'));
    final operation = rows.first['operation_id'] as String;
    expect(await restarted.markResolved(project: 'p', owner: 'b', conversation: 'chat',
        operationId: operation, permitted: () => true), isFalse);
    expect(await restarted.markResolved(project: 'p', owner: 'a', conversation: 'chat',
        operationId: operation, permitted: () => true), isTrue);
    expect(await restarted.append(project: 'p', owner: 'a', sessionId: 's-a',
        conversation: 'chat', draft: {'text': 'after recovery'}, permitted: () => true), isTrue);
    final after = await restarted.pending(project: 'p', owner: 'a', conversation: 'chat',
        permitted: () => true);
    expect(after, hasLength(DraftRecoveryJournal.maxOwnerEntries));
    expect(after.any((item) => (item['draft'] as Map)['text'] == 'edit 0'), isTrue);
  });

  test('logout before a delayed open cannot start a journal transaction', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final release = Completer<Database>();
    final journal = DraftRecoveryJournal(open: () => release.future);
    var permitted = true;
    final pending = journal.append(project: 'p', owner: 'a', sessionId: 's-a',
        conversation: 'chat', draft: {'text': 'draft'}, permitted: () => permitted);
    permitted = false;
    release.complete(db);
    expect(await pending, isFalse);
    expect(await journal.pending(project: 'p', owner: 'a', conversation: 'chat',
        permitted: () => true), isEmpty);
  });

  test('supersession is atomic and isolated to one writer stream', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final journal = DraftRecoveryJournal(open: () async => db);
    Future<bool> append(String stream, String text) => journal.append(
        project: 'p', owner: 'a', sessionId: 's', conversation: 'chat',
        streamId: stream, draft: {'text': text}, permitted: () => true);
    expect(await append('writer-1', 'old'), isTrue);
    expect(await append('writer-2', 'other window'), isTrue);
    await db.execute("CREATE TRIGGER reject_new BEFORE INSERT ON draft_recovery "
        "WHEN NEW.payload LIKE '%reject-me%' BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    await expectLater(append('writer-1', 'reject-me'), throwsA(isA<DatabaseException>()));
    var entries = await journal.pending(project: 'p', owner: 'a', conversation: 'chat', permitted: () => true);
    expect(entries.map((row) => (row['draft'] as Map)['text']), containsAll(['old', 'other window']));
    await db.execute('DROP TRIGGER reject_new');
    final writes = await Future.wait(List.generate(30, (i) => append('writer-1', 'edit $i')));
    expect(writes.every((value) => value), isTrue);
    entries = await journal.pending(project: 'p', owner: 'a', conversation: 'chat', permitted: () => true);
    expect(entries, hasLength(2));
    expect(entries.map((row) => (row['draft'] as Map)['text']), contains('other window'));
    expect(entries.where((row) => (row['draft'] as Map)['text'] != 'other window').single['draft'],
        containsPair('text', 'edit 29'));
  });
}
