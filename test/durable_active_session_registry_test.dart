import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/core/guarded_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('scoped transitions, same-SID refresh, ABA and competing engines',
      () async {
    final root = await Directory.systemTemp.createTemp('active-registry-');
    final path = '${root.path}/registry.db';
    Future<Database> open() => databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final firstDb = await open(), secondDb = await open();
    addTearDown(() async {
      await firstDb.close();
      await secondDb.close();
      await root.delete(recursive: true);
    });
    final first =
        DurableActiveSessionRegistry(firstDb, 'https://PROJECT.test/');
    final second =
        DurableActiveSessionRegistry(secondDb, 'https://project.test');
    await first.initialize();
    await second.initialize();
    final empty = (await first.read())!, staleEmpty = (await second.read())!;
    final login = await first.begin(empty,
        nextUid: 'a', nextSid: 'sid-a', current: () => true);
    expect(login, isNotNull);
    expect((await second.read())?.state, 'transition');
    expect(
        await second.begin(staleEmpty,
            nextUid: 'b', nextSid: 'sid-b', current: () => true),
        isNull);
    expect(await first.finish(login!, current: () => true), isTrue);
    final active = (await first.read())!, otherActive = (await second.read())!;
    Future<bool> permitted(ActiveSessionSnapshot s) => firstDb.transaction(
        (txn) => first.permitsInTransaction(txn, s, uid: 'a', sid: 'sid-a'));
    expect(await permitted(active), isTrue);
    expect(
        await secondDb.transaction((txn) =>
            first.permitsInTransaction(txn, active, uid: 'a', sid: 'sid-a')),
        isFalse,
        reason: 'another connection is not the bound transaction');
    final foreignDb = await databaseFactoryFfi.openDatabase(
        '${root.path}/foreign.db',
        options: OpenDatabaseOptions(singleInstance: false));
    final foreign =
        DurableActiveSessionRegistry(foreignDb, 'https://project.test');
    await foreign.initialize();
    final foreignLogin = await foreign.begin((await foreign.read())!,
        nextUid: 'a', nextSid: 'sid-a', current: () => true);
    expect(await foreign.finish(foreignLogin!, current: () => true), isTrue);
    await foreignDb
        .update('active_session_registry', {'instance': active.instance});
    expect(
        await foreignDb.transaction((txn) =>
            first.permitsInTransaction(txn, active, uid: 'a', sid: 'sid-a')),
        isFalse,
        reason: 'matching rows in a foreign DB must not authorize');
    await foreignDb.close();
    final wrapped = DurableActiveSessionRegistry(
        GuardedDatabase(firstDb, () async {}), 'https://project.test');
    final wrappedSnapshot = (await wrapped.read())!;
    expect(
        await wrapped.db.transaction((txn) => wrapped.permitsInTransaction(
            txn, wrappedSnapshot,
            uid: 'a', sid: 'sid-a')),
        isTrue,
        reason: 'the real guarded wrapper delegates to its bound connection');
    // Token rotation does not change owner/SID; authorization remains the
    // responsibility of the caller and no registry transition is required.
    expect(await permitted(active), isTrue);
    expect(
        await firstDb.transaction((txn) => first
            .permitsInTransaction(txn, active, uid: 'a', sid: 'different-sid')),
        isFalse);
    final logout = await second.begin(otherActive, current: () => true);
    expect(logout, isNotNull);
    expect(await permitted(active), isFalse);
    expect(await second.finish(logout!, current: () => true), isTrue);
    final relogin = await first.begin((await first.read())!,
        nextUid: 'a', nextSid: 'sid-a', current: () => true);
    expect(await first.finish(relogin!, current: () => true), isTrue);
    expect(await permitted(active), isFalse,
        reason: 'same owner and SID cannot revive an old generation');
    expect(
        await second.begin(otherActive,
            nextUid: 'b', nextSid: 'sid-b', current: () => true),
        isNull);
    expect(await permitted((await first.read())!), isTrue);
    final beforeReplacement = (await first.read())!;
    await secondDb.update(
        'active_session_registry', {'instance': 'replacement-instance'});
    expect(await permitted(beforeReplacement), isFalse,
        reason:
            'a registry with a different durable instance cannot revive old snapshots');
  });

  test('project identity accepts one canonical origin and rejects ambiguity',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(db.close);
    expect(DurableActiveSessionRegistry(db, 'https://EXAMPLE.test/').project,
        'https://example.test');
    for (final value in [
      'http://example.test',
      'https://a@example.test',
      'https://example.test/path',
      'https://example.test?x=1',
      'https://example.test#x',
      ' https://example.test'
    ]) {
      expect(
          () => DurableActiveSessionRegistry(db, value), throwsArgumentError);
    }
  });

  test(
      'interrupted transition persists blocked across reopen; stale completion fails',
      () async {
    final root =
        await Directory.systemTemp.createTemp('active-registry-crash-');
    final path = '${root.path}/registry.db';
    Future<Database> open() => databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final db = await open();
    final first = DurableActiveSessionRegistry(db, 'https://project.test');
    await first.initialize();
    var current = true;
    final pending = await first.begin((await first.read())!,
        nextUid: 'a', nextSid: 'sid-a', current: () => current);
    expect(pending, isNotNull);
    current = false;
    expect(await first.finish(pending!, current: () => current), isFalse);
    await db.close(); // Model a dead handle with an unfinished durable intent.
    final reopenedDb = await open();
    final reopened =
        DurableActiveSessionRegistry(reopenedDb, 'https://project.test');
    final blocked = (await reopened.read())!;
    expect(blocked.state, 'transition');
    expect(
        await reopened.begin(blocked,
            nextUid: 'b', nextSid: 'sid-b', current: () => true),
        isNull);
    expect(await reopened.finish(pending, current: () => true), isFalse,
        reason: 'a ticket from a different registry handle has no authority');
    await reopenedDb.close();
    await root.delete(recursive: true);
  });
}
