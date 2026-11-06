import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/forward/durable_forward_outbox.dart';
import 'package:student_platform/src/ui/chats/forward/sent_forward_sentinel.dart';
import 'package:student_platform/src/ui/learning/models/local_attach.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  sqfliteFfiInit();

  for (final phase in <String, DurableForwardState?>{
    'reserved_unverified': DurableForwardState.reservedUnverified,
    'preparing_unknown': DurableForwardState.preparingUnknown,
    'ready': DurableForwardState.ready,
    'sending_unknown': DurableForwardState.sendingUnknown,
    'sent': DurableForwardState.sent,
    'acknowledged': null,
    'canceled': null,
  }.entries) {
    test('process exits without closing SQLite after ${phase.key}', () async {
      final temp = await Directory.systemTemp.createTemp('forward_crash_qa_');
      var childMayBeActive = false;
      addTearDown(() async {
        // Preserve the synthetic DB when a timeout leaves child state uncertain.
        if (childMayBeActive) return;
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final target = await temp.resolveSymbolicLinks();
        if (!p.isWithin(root, target)) throw StateError('Invalid QA directory');
        await temp.delete(recursive: true);
      });
      var flutterRoot = Platform.environment['FLUTTER_ROOT'];
      var search = Directory(p.dirname(Platform.resolvedExecutable));
      while (flutterRoot == null || flutterRoot.isEmpty) {
        if (File(p.join(search.path, 'bin', 'cache', 'flutter_tools.snapshot'))
            .existsSync()) {
          flutterRoot = search.path;
          break;
        }
        if (search.parent.path == search.path) break;
        search = search.parent;
      }
      if (flutterRoot == null || flutterRoot.isEmpty) {
        throw StateError('Set FLUTTER_ROOT for isolated crash test');
      }
      final dart = p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin',
          Platform.isWindows ? 'dart.exe' : 'dart');
      final tool =
          p.join(flutterRoot, 'bin', 'cache', 'flutter_tools.snapshot');
      if (!File(dart).existsSync() || !File(tool).existsSync())
        throw StateError('Set FLUTTER_ROOT for isolated crash test');
      final dbPath = p.join(temp.path, 'outbox.db');
      final child = await Process.start(
          dart,
          [
            tool,
            'test',
            '--no-pub',
            p.join('tool', 'qa_forward_crash_worker_test.dart')
          ],
          workingDirectory: Directory.current.path,
          environment: {
            ...Platform.environment,
            'FORWARD_CRASH_QA_DB': dbPath,
            'FORWARD_CRASH_QA_PHASE': phase.key
          });
      childMayBeActive = true;
      final stdoutDone = child.stdout.transform(utf8.decoder).join();
      final stderrDone = child.stderr.transform(utf8.decoder).join();
      final int result;
      try {
        result = await child.exitCode.timeout(const Duration(seconds: 45));
      } on TimeoutException {
        child.kill();
        rethrow;
      }
      final output = (await Future.wait([stdoutDone, stderrDone])
              .timeout(const Duration(seconds: 10)))
          .join('\n');
      childMayBeActive = false;
      expect(result, isNot(0));
      if (!await File('$dbPath.marker').exists()) {
        final category = output.contains('Unsafe QA path')
            ? 'invalid temporary path'
            : output.contains('Invalid QA phase')
                ? 'invalid phase'
                : output.contains('Another flutter command')
                    ? 'Flutter startup lock'
                    : output.contains('Could not resolve')
                        ? 'dependency resolution'
                        : 'unclassified child failure; raw output withheld';
        throw TestFailure('Crash worker ${phase.key}: exit=$result, $category');
      }
      expect(await File('$dbPath.marker').readAsString(), phase.key);
      final events = StreamController<AuthState>.broadcast(sync: true);
      final session = fakeSession('qa-user');
      final scope = AuthSessionScope(
          currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      final db =
          await openDurableForwardDatabase(dbPath, factory: databaseFactoryFfi);
      final outbox = DurableForwardOutbox(db, scope, 'qa-backend');
      final owner = scope.capture()!;
      final restored = await outbox.peek(owner, 'target');
      expect(restored?.state, phase.value);
      if (phase.key == 'acknowledged' || phase.key == 'canceled') {
        final terminal = await outbox.terminalOperations(owner, 'target');
        expect(terminal, hasLength(1));
        final rows = await db.rawQuery('SELECT kind FROM forward_terminal');
        expect(rows.single['kind'],
            phase.key == 'acknowledged' ? 'sent' : 'canceled');
        // A separate synthetic draft models crash before UI cleanup; this is
        // not a SharedPreferences integration test.
        final draft = jsonDecode(await File('$dbPath.draft').readAsString())
            as Map<String, dynamic>;
        final files = (draft['files'] as List)
            .map((raw) => LocalAttach(
                localId: raw['id'] as String,
                path: raw['path'] as String,
                name: 'synthetic',
                mimeType: 'test',
                size: 0,
                isImage: false))
            .toList();
        files.removeWhere((file) => isTerminalForwardSentinel(file, terminal));
        expect(draft['text'], 'new draft');
        expect(files.map((file) => file.localId), ['new-file']);
      }
      if (phase.key == 'sending_unknown' || phase.key == 'sent') {
        expect(restored!.sentText, isNotEmpty);
      }
      await db.close();
      scope.dispose();
      await events.close();
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  for (final oldVersion in [2, 3, 4]) {
    test('real SQLite v$oldVersion upgrade preserves queued row', () async {
      final temp = await Directory.systemTemp.createTemp('forward_upgrade_qa_');
      addTearDown(() async {
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final target = await temp.resolveSymbolicLinks();
        if (!p.isWithin(root, target)) throw StateError('Invalid QA directory');
        await temp.delete(recursive: true);
      });
      final dbPath = p.join(temp.path, 'outbox.db');
      final old = await databaseFactoryFfi.openDatabase(dbPath,
          options: OpenDatabaseOptions(
              version: oldVersion,
              onCreate: (db, _) async {
                await db.execute('CREATE TABLE forward_item ('
                    'backend TEXT NOT NULL, uid TEXT NOT NULL, chat TEXT NOT NULL, '
                    'op TEXT NOT NULL, version INTEGER NOT NULL, state TEXT NOT NULL, '
                    'source TEXT NOT NULL, source_urls TEXT NOT NULL, source_ids TEXT NOT NULL, '
                    'prepared TEXT, prepared_ids TEXT, sent_text TEXT, reply_id TEXT, sent_ids TEXT, message_id TEXT, '
                    'PRIMARY KEY (backend,uid,chat))');
                await db.execute('CREATE TABLE forward_legacy_import ('
                    'backend TEXT NOT NULL, uid TEXT NOT NULL, chat TEXT NOT NULL, '
                    'fingerprint TEXT NOT NULL, operation TEXT NOT NULL, '
                    'PRIMARY KEY (backend,uid,chat,fingerprint))');
                if (oldVersion == 4) {
                  await db.execute('CREATE TABLE forward_sent ('
                      'backend TEXT NOT NULL,uid TEXT NOT NULL,chat TEXT NOT NULL,operation TEXT NOT NULL,'
                      'PRIMARY KEY (backend,uid,chat,operation))');
                  await db.rawInsert(
                      'INSERT INTO forward_sent VALUES (?,?,?,?)',
                      ['qa', 'user', 'chat', 'old-operation']);
                }
              }));
      await old.rawInsert(
          'INSERT INTO forward_item (backend,uid,chat,op,version,state,source,source_urls,source_ids) VALUES (?,?,?,?,?,?,?,?,?)',
          ['qa', 'user', 'chat', 'op', 4, 'queued', 'source', '[]', '[]']);
      await old.close();
      final upgraded =
          await openDurableForwardDatabase(dbPath, factory: databaseFactoryFfi);
      final rows = await upgraded
          .rawQuery('SELECT op,version,state,source FROM forward_item');
      expect(rows.single, {
        'op': 'op',
        'version': 4,
        'state': oldVersion == 2 ? 'reserved_unverified' : 'queued',
        'source': 'source'
      });
      expect(await upgraded.getVersion(), 5);
      if (oldVersion == 4) {
        final terminal = await upgraded
            .rawQuery('SELECT operation,kind FROM forward_terminal');
        expect(terminal.single, {'operation': 'old-operation', 'kind': 'sent'});
      }
      await upgraded.close();
    });
  }

  test('real SQLite reopens unknown then confirmed without resending',
      () async {
    final temp = await Directory.systemTemp.createTemp('forward_sqlite_qa_');
    addTearDown(() async {
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await temp.resolveSymbolicLinks();
      if (!p.isWithin(root, target)) throw StateError('Invalid QA directory');
      await temp.delete(recursive: true);
    });
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('qa-user');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    addTearDown(() async {
      scope.dispose();
      await events.close();
    });
    final owner = scope.capture()!;
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'test',
          files: const [])
    ]).encodeForText();
    final dbPath = p.join(temp.path, 'outbox.db');
    var db =
        await openDurableForwardDatabase(dbPath, factory: databaseFactoryFfi);
    final separate =
        await openDurableForwardDatabase(dbPath, factory: databaseFactoryFfi);
    await separate.close();
    expect(await db.getVersion(), 5);
    var outbox = DurableForwardOutbox(db, scope, 'qa-backend');
    final initial = await outbox.reserve(owner, 'target',
        source: source, sourceUrls: [], sourceIds: []);
    final queued = await outbox.confirmReservation(initial);
    final preparing = await outbox.markPreparing(queued);
    final ready = await outbox.markReady(preparing,
        prepared: source, preparedIds: [], uploadedIdsBySource: {});
    final unknown = await outbox
        .markSending(ready, text: source, replyId: null, fileIds: []);
    expect(unknown.state, DurableForwardState.sendingUnknown);
    await db.close();
    db = await openDurableForwardDatabase(dbPath, factory: databaseFactoryFfi);
    outbox = DurableForwardOutbox(db, scope, 'qa-backend');
    final recovered = (await outbox.peek(owner, 'target'))!;
    expect(recovered.state, DurableForwardState.sendingUnknown);
    expect(recovered.sentText, source);
    var calls = 0;
    final sent =
        await outbox.retryUnknownByUser(recovered, send: (snapshot) async {
      calls++;
      expect(snapshot.text, source);
      return '12345678-1234-1234-1234-123456789abc';
    });
    expect(calls, 1);
    expect(sent.state, DurableForwardState.sent);
    await db.close();
    db = await openDurableForwardDatabase(dbPath, factory: databaseFactoryFfi);
    outbox = DurableForwardOutbox(db, scope, 'qa-backend');
    final confirmed = (await outbox.peek(owner, 'target'))!;
    expect(confirmed.state, DurableForwardState.sent);
    expect(calls, 1);
    await outbox.acknowledgeSent(confirmed);
    expect(await outbox.peek(owner, 'target'), isNull);
    expect(await outbox.terminalOperations(owner, 'target'),
        {confirmed.operation});
    expect(await outbox.terminalOperations(owner, 'other-chat'), isEmpty);
    expect(
        await DurableForwardOutbox(db, scope, 'other-backend')
            .terminalOperations(owner, 'target'),
        isEmpty);
    final otherEvents = StreamController<AuthState>.broadcast(sync: true);
    final otherSession = fakeSession('another-user');
    final otherScope = AuthSessionScope(
        currentSession: () => otherSession, authEvents: otherEvents.stream);
    otherEvents.add(AuthState(AuthChangeEvent.initialSession, otherSession));
    final otherOutbox = DurableForwardOutbox(db, otherScope, 'qa-backend');
    expect(
        await otherOutbox.terminalOperations(otherScope.capture()!, 'target'),
        isEmpty);
    otherScope.dispose();
    await otherEvents.close();
    await db.close();
  });
}
