import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/forward/durable_forward_outbox.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;
import 'forward_outbox_store_test.dart' show Storage;

// Contract double: validates transitions, not SQLite crash durability.
class _Db implements Database, Transaction {
  Map<String, Object?>? row;
  bool failUpdate = false;
  bool failMarker = false;
  bool failTombstone = false;
  Completer<void>? insertEntered, insertRelease;
  Completer<void>? updateEntered, updateRelease;
  Completer<void>? queuedCommitEntered, queuedCommitRelease;
  final markers = <String, String>{};
  final tombstones = <String, String>{};
  @override
  Future<void> close() async {}
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    final before = row == null ? null : Map<String, Object?>.of(row!);
    final oldMarkers = Map<String, String>.of(markers);
    final oldTombstones = Map<String, String>.of(tombstones);
    try {
      final result = await action(this);
      if (row?['state'] == 'queued' && queuedCommitEntered != null) {
        queuedCommitEntered!.complete();
        await queuedCommitRelease!.future;
        queuedCommitEntered = null;
      }
      return result;
    } catch (_) {
      row = before;
      markers
        ..clear()
        ..addAll(oldMarkers);
      tombstones
        ..clear()
        ..addAll(oldTombstones);
      rethrow;
    }
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    if (sql.contains('FROM forward_terminal') &&
        sql.startsWith('SELECT kind')) {
      final kind = tombstones[arguments!.join('|')];
      return kind == null
          ? []
          : [
              {'kind': kind}
            ];
    }
    if (sql.contains('FROM forward_terminal')) {
      final prefix = '${arguments!.join('|')}|';
      return tombstones.keys
          .where((key) => key.startsWith(prefix))
          .map((key) =>
              <String, Object?>{'operation': key.substring(prefix.length)})
          .toList();
    }
    if (sql.contains('FROM forward_legacy_import')) {
      final key = arguments!.join('|');
      final op = markers[key];
      return op == null
          ? []
          : [
              {'operation': op}
            ];
    }
    final r = row;
    if (r == null ||
        r['backend'] != arguments![0] ||
        r['uid'] != arguments[1] ||
        r['chat'] != arguments[2]) return [];
    return [Map<String, Object?>.of(r)];
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    final a = arguments!;
    if (sql.startsWith('INSERT OR IGNORE INTO forward_terminal')) {
      if (failTombstone) throw StateError('tombstone failed');
      tombstones.putIfAbsent(a.take(4).join('|'), () => a[4] as String);
      return 1;
    }
    if (sql.startsWith('INSERT INTO forward_legacy_import')) {
      if (failMarker) throw StateError('marker failed');
      markers[a.take(4).join('|')] = a[4] as String;
      return 1;
    }
    insertEntered?.complete();
    await insertRelease?.future;
    if (row != null) throw StateError('occupied');
    row = {
      'backend': a[0],
      'uid': a[1],
      'chat': a[2],
      'op': a[3],
      'version': 0,
      'state': a[4],
      'source': a[5],
      'source_urls': a[6],
      'source_ids': a[7]
    };
    return 1;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    if (failUpdate) throw StateError('write failed');
    updateEntered?.complete();
    await updateRelease?.future;
    final a = arguments!, r = row;
    if (r == null ||
        r['backend'] != a[7] ||
        r['uid'] != a[8] ||
        r['chat'] != a[9] ||
        r['op'] != a[10] ||
        r['version'] != a[11] ||
        r['state'] != a[12]) return 0;
    r['version'] = (r['version'] as int) + 1;
    r['state'] = a[0];
    for (final entry in {
      'prepared': a[1],
      'prepared_ids': a[2],
      'message_id': a[3],
      'sent_text': a[4],
      'reply_id': a[5],
      'sent_ids': a[6]
    }.entries) {
      if (entry.value != null) r[entry.key] = entry.value;
    }
    return 1;
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async {
    final a = arguments!, r = row;
    if (r == null ||
        r['backend'] != a[0] ||
        r['uid'] != a[1] ||
        r['chat'] != a[2] ||
        r['op'] != a[3] ||
        r['version'] != a[4] ||
        r['state'] != a[5]) return 0;
    row = null;
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('host injects isolated database without platform services',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final db = _Db(), storage = Storage();
    late ForwardOutboxSession captured;
    late BuildContext capturedContext;
    final Future<Database> Function() openDb = () async => db;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: storage,
            durableMode: true,
            openDatabaseOverride: openDb,
            backendOverride: 'qa-backend',
            child: Builder(builder: (context) {
              capturedContext = context;
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    final durable = await ForwardOutboxHost.durable(capturedContext);
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'text',
          files: const [])
    ]).encodeForText();
    await captured.putDurableForChat(durable,
        chatId: 'target', text: source, isSourceCurrent: () => true);
    final receipt = (await captured.claimDurableForChat('target', durable))!;
    expect(receipt.state, DurableForwardState.queued);
    expect(captured.consumeAutoApproval(durable, receipt)?.call(), isTrue);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });
  testWidgets('source changes during ready commit cannot retain auto proof',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    late ForwardOutboxSession captured;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: Storage(),
            durableMode: true,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    final db = _Db();
    final durable = DurableForwardOutbox(db, scope, 'backend');
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'text',
          files: const [])
    ]).encodeForText();
    var current = true;
    await captured.putDurableForChat(durable,
        chatId: 'target', text: source, isSourceCurrent: () => current);
    final queued = (await captured.claimDurableForChat('target', durable))!;
    final ticket = captured.consumeAutoApproval(durable, queued)!;
    final preparing = await durable.markPreparing(queued);
    db.updateEntered = Completer();
    db.updateRelease = Completer();
    final pending = durable.markReady(preparing,
        prepared: source, preparedIds: [], uploadedIdsBySource: {});
    await db.updateEntered!.future;
    current = false;
    db.updateRelease!.complete();
    final ready = await pending;
    expect(ready.state, DurableForwardState.ready);
    expect(ticket(), isFalse);
    expect(captured.consumeAutoApproval(durable, ready), isNull);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });
  testWidgets('source changes during commit leave no automatic approval',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    late ForwardOutboxSession captured;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: storage,
            durableMode: true,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    final db = _Db()
      ..queuedCommitEntered = Completer()
      ..queuedCommitRelease = Completer();
    final durable = DurableForwardOutbox(db, scope, 'backend');
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'text',
          files: const [])
    ]).encodeForText();
    var current = true;
    final pending = captured.putDurableForChat(durable,
        chatId: 'target', text: source, isSourceCurrent: () => current);
    await db.queuedCommitEntered!.future;
    current = false;
    db.queuedCommitRelease!.complete();
    await expectLater(pending, throwsStateError);
    final receipt = (await captured.claimDurableForChat('target', durable))!;
    expect(receipt.state, DurableForwardState.queued);
    expect(captured.consumeAutoApproval(durable, receipt), isNull);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });
  test('auto approval is one-shot, owner-bound and absent after restart',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final old = scope.capture()!;
    final coordinator = ForwardOutboxCoordinator(Storage());
    var current = true;
    coordinator.recordAutoApproval('backend', old, 'chat', 'op', () => current);
    expect(
        ForwardOutboxCoordinator(Storage())
            .consumeAutoApproval('backend', old, 'chat', 'op'),
        isNull);
    final ticket =
        coordinator.consumeAutoApproval('backend', old, 'chat', 'op')!;
    expect(ticket(), isTrue);
    current = false;
    expect(ticket(), isFalse);
    expect(
        coordinator.consumeAutoApproval('backend', old, 'chat', 'op'), isNull);
    coordinator.recordAutoApproval('backend', old, 'chat', 'new', () => true);
    session = fakeSession('a', access: 'new-session');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(
        coordinator.consumeAutoApproval(
            'backend', scope.capture()!, 'chat', 'new'),
        isNull);
    scope.dispose();
    await events.close();
  });
  test('changed source during SQLite insert rolls reservation back', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final db = _Db()
      ..insertEntered = Completer()
      ..insertRelease = Completer();
    final store = DurableForwardOutbox(db, scope, 'backend');
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'text',
          files: const [])
    ]).encodeForText();
    var sourceCurrent = true;
    final pending = store.reserve(scope.capture()!, 'target',
        source: source,
        sourceUrls: [],
        sourceIds: [],
        isSourceCurrent: () => sourceCurrent);
    await db.insertEntered!.future;
    sourceCurrent = false;
    db.insertRelease!.complete();
    await expectLater(pending, throwsA(isA<DurableForwardChanged>()));
    expect(db.row, isNull);
    scope.dispose();
    await events.close();
  });
  testWidgets('unbound legacy stays untouched and blocks new reservation',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    late ForwardOutboxSession captured;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: storage,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    final db = _Db();
    final durable = DurableForwardOutbox(db, scope, 'backend');
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'text',
          files: const [])
    ]).encodeForText();
    await captured.putForChat(chatId: 'target', text: source);
    final old = storage.values['forward_outbox_a_target'];
    await tester.pumpWidget(const SizedBox());
    final afterRestart = Storage()..values.addAll(storage.values);
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            key: const ValueKey('durable-host'),
            source: scope,
            storage: afterRestart,
            durableMode: true,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    await expectLater(
        captured.putForChat(chatId: 'target', text: source), throwsStateError);
    await expectLater(captured.tryTakeForChat('target'), throwsStateError);
    await expectLater(captured.claimDurableForChat('target', durable),
        throwsA(isA<LegacyForwardProvenanceUnknown>()));
    expect(afterRestart.values['forward_outbox_a_target'], old);
    expect(await durable.peek(scope.capture()!, 'target'), isNull);
    await expectLater(
        captured.putDurableForChat(durable,
            chatId: 'target', text: source, isSourceCurrent: () => true),
        throwsA(isA<DurableForwardOccupied>()));
    var sourceCurrent = true;
    await captured.putDurableForChat(durable,
        chatId: 'another', text: source, isSourceCurrent: () => sourceCurrent);
    final queued = (await captured.claimDurableForChat('another', durable))!;
    expect(queued.state, DurableForwardState.queued);
    final ticket = captured.consumeAutoApproval(durable, queued)!;
    expect(ticket(), isTrue);
    expect(captured.consumeAutoApproval(durable, queued), isNull);
    db.updateEntered = Completer();
    db.updateRelease = Completer();
    final transition = durable.markPreparing(queued);
    await db.updateEntered!.future;
    sourceCurrent = false;
    db.updateRelease!.complete();
    await transition;
    expect(ticket(), isFalse);
    expect((await durable.peek(scope.capture()!, 'another'))!.state,
        DurableForwardState.preparingUnknown);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });

  test('legacy import transaction survives retry and prevents resurrection',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = scope.capture()!, db = _Db();
    final store = DurableForwardOutbox(db, scope, 'backend');
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'text',
          files: const [])
    ]).encodeForText();
    final fingerprint = 'a' * 64;
    Future<LegacyForwardImport> migrate() => store.importLegacy(owner, 'target',
        fingerprint: fingerprint,
        source: source,
        sourceUrls: [],
        sourceIds: []);
    db.failMarker = true;
    await expectLater(migrate(), throwsStateError);
    expect(db.row, isNull);
    expect(db.markers, isEmpty);
    db.failMarker = false;
    expect(await migrate(), LegacyForwardImport.imported);
    expect(await migrate(), LegacyForwardImport.alreadyImported);
    final imported = (await store.peek(owner, 'target'))!;
    expect(imported.state, DurableForwardState.reservedUnverified);
    final queued = await store.confirmReservation(imported);
    final preparing = await store.markPreparing(queued);
    final ready = await store.markReady(preparing,
        prepared: source, preparedIds: [], uploadedIdsBySource: {});
    final sent = await store.sendOnce(ready,
        text: source,
        replyId: null,
        fileIds: [],
        send: (_) async => '12345678-1234-1234-1234-123456789abc');
    await store.acknowledgeSent(sent);
    expect(await store.peek(owner, 'target'), isNull);
    expect(await migrate(), LegacyForwardImport.alreadyImported);
    expect(await store.peek(owner, 'target'), isNull);
    final canceled = await store.reserve(owner, 'target',
        source: source, sourceUrls: [], sourceIds: []);
    await expectLater(
        store.importLegacy(owner, 'target',
            fingerprint: 'b' * 64,
            source: source,
            sourceUrls: [],
            sourceIds: []),
        throwsA(isA<DurableForwardOccupied>()));
    expect(db.markers.length, 1);
    db.failTombstone = true;
    await expectLater(store.cancelByUser(canceled), throwsStateError);
    expect((await store.peek(owner, 'target'))!.operation, canceled.operation);
    db.failTombstone = false;
    await store.cancelByUser(canceled);
    expect(db.tombstones['backend|a|target|${canceled.operation}'], 'canceled');
    expect(await store.terminalOperations(owner, 'target'),
        contains(canceled.operation));
    scope.dispose();
    await events.close();
  });

  test('unknown send persists and only confirmed UUID can be acknowledged',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = scope.capture()!;
    final db = _Db();
    final store = DurableForwardOutbox(db, scope, 'backend');
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'text',
          files: const [])
    ]).encodeForText();
    final reserved = await store.reserve(owner, 'target',
        source: source, sourceUrls: [], sourceIds: []);
    await expectLater(
        store.reserve(owner, 'target',
            source: source, sourceUrls: [], sourceIds: []),
        throwsA(isA<DurableForwardOccupied>()));
    expect(reserved.state, DurableForwardState.reservedUnverified);
    final queued = await store.confirmReservation(reserved);
    final preparing = await store.markPreparing(queued);
    await expectLater(
        store.markPreparing(queued), throwsA(isA<DurableForwardChanged>()));
    final ready = await store.markReady(preparing,
        prepared: source, preparedIds: [], uploadedIdsBySource: {});
    final different =
        ForwardPayload(fromChatId: 'other', items: const []).encodeForText();
    expect(
        () => store
            .markSending(ready, text: different, replyId: null, fileIds: []),
        throwsFormatException);
    db.failUpdate = true;
    await expectLater(
        store.markSending(ready, text: source, replyId: null, fileIds: []),
        throwsStateError);
    db.failUpdate = false;
    expect(
        (await store.peek(owner, 'target'))!.state, DurableForwardState.ready);
    await store.markSending(ready, text: source, replyId: null, fileIds: []);
    final reopened = DurableForwardOutbox(db, scope, 'backend');
    final pending = (await reopened.peek(owner, 'target'))!;
    expect(pending.state, DurableForwardState.sendingUnknown);
    expect(pending.sentText, source);
    await expectLater(reopened.acknowledgeSent(pending),
        throwsA(isA<DurableForwardChanged>()));
    await expectLater(
        reopened.retryUnknownByUser(pending, send: (_) async => ''),
        throwsFormatException);
    final stillUnknown = (await reopened.peek(owner, 'target'))!;
    expect(stillUnknown.state, DurableForwardState.sendingUnknown);
    final sent =
        await reopened.retryUnknownByUser(stillUnknown, send: (snapshot) async {
      expect(snapshot.chat, 'target');
      expect(snapshot.text, source);
      return '12345678-1234-1234-1234-123456789abc';
    });
    db.failTombstone = true;
    await expectLater(reopened.acknowledgeSent(sent), throwsStateError);
    expect((await reopened.peek(owner, 'target'))!.state,
        DurableForwardState.sent);
    expect(await reopened.terminalOperations(owner, 'target'), isEmpty);
    db.failTombstone = false;
    expect(await reopened.acknowledgeSent(sent), isTrue);
    expect(
        await reopened.terminalOperations(owner, 'target'), {sent.operation});
    expect(
        await DurableForwardOutbox(db, scope, 'other-backend')
            .terminalOperations(owner, 'target'),
        isEmpty);
    expect(await reopened.peek(owner, 'target'), isNull);
    final next = await reopened.reserve(owner, 'target',
        source: source, sourceUrls: [], sourceIds: []);
    final nextQueued = await reopened.confirmReservation(next);
    final nextPreparing = await reopened.markPreparing(nextQueued);
    final nextReady = await reopened.markReady(nextPreparing,
        prepared: source, preparedIds: [], uploadedIdsBySource: {});
    await expectLater(
        reopened.sendOnce(nextReady, text: source, replyId: null, fileIds: [],
            send: (_) async {
          session = fakeSession('a', access: 'new-session');
          events.add(AuthState(AuthChangeEvent.signedIn, session));
          return '12345678-1234-1234-1234-123456789abc';
        }),
        throwsStateError);
    final newOwner = scope.capture()!;
    expect((await reopened.peek(newOwner, 'target'))!.state,
        DurableForwardState.sendingUnknown);
    scope.dispose();
    await events.close();
  });
}
