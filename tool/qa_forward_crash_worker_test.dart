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
import 'package:supabase_flutter/supabase_flutter.dart';
import '../test/auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  sqfliteFfiInit();
  final testPath = Platform.environment['FORWARD_CRASH_QA_DB'];
  final phase = Platform.environment['FORWARD_CRASH_QA_PHASE'];
  test('isolated crash worker', () async {
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    final dbPath = p.normalize(p.absolute(testPath!));
    if (!p.isWithin(temp, dbPath) ||
        !p.basename(p.dirname(dbPath)).startsWith('forward_crash_qa_') ||
        p.basename(dbPath) != 'outbox.db') {
      throw StateError('Unsafe QA path');
    }
    if (!{
      'reserved_unverified',
      'preparing_unknown',
      'ready',
      'sending_unknown',
      'sent',
      'acknowledged',
      'canceled'
    }.contains(phase)) {
      throw StateError('Invalid QA phase');
    }
    Future<void> stopAt(String step) async {
      if (phase != step) return;
      await File('$dbPath.marker').writeAsString(step, flush: true);
      exit(91);
    }

    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('qa-user');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final db =
        await openDurableForwardDatabase(dbPath, factory: databaseFactoryFfi);
    final outbox = DurableForwardOutbox(db, scope, 'qa-backend');
    final source = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: 'test',
          files: const [])
    ]).encodeForText();
    final unverified = await outbox.reserve(scope.capture()!, 'target',
        source: source, sourceUrls: [], sourceIds: []);
    await stopAt('reserved_unverified');
    final queued = await outbox.confirmReservation(unverified);
    final preparing = await outbox.markPreparing(queued);
    await stopAt('preparing_unknown');
    final ready = await outbox.markReady(preparing,
        prepared: source, preparedIds: [], uploadedIdsBySource: {});
    await stopAt('ready');
    if (phase == 'canceled' || phase == 'acknowledged') {
      await File('$dbPath.draft').writeAsString(
          jsonEncode({
            'text': 'new draft',
            'files': [
              {'id': 'durable-forward:${ready.operation}', 'path': '__FG__'},
              {'id': 'new-file', 'path': '/new-file'},
            ]
          }),
          flush: true);
    }
    if (phase == 'canceled') {
      await outbox.cancelByUser(ready);
      await stopAt('canceled');
    }
    if (phase == 'sent' || phase == 'acknowledged') {
      final sent = await outbox.sendOnce(ready,
          text: source,
          replyId: null,
          fileIds: [],
          send: (_) async => '12345678-1234-1234-1234-123456789abc');
      await stopAt('sent');
      await outbox.acknowledgeSent(sent);
      await stopAt('acknowledged');
    }
    await outbox.markSending(ready, text: source, replyId: null, fileIds: []);
    await stopAt('sending_unknown');
    throw StateError('Unreachable QA phase');
  }, skip: testPath == null ? 'Dedicated isolated child only' : false);
}
