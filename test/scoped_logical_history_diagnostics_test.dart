import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late Database db;
  late StreamController<AuthState> events;
  late AuthSessionScope scope;
  late SessionCapabilities caps;
  late ProjectChatServerCache cache;
  late OfflineSessionBinding binding;
  late Session session;
  late String expectedPayload;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('scoped_history_');
    db = await openProjectChatServerDatabase('${dir.path}/history.db',
        factory: databaseFactoryFfi);
    events = StreamController<AuthState>.broadcast(sync: true);
    session = fakeSession('owner');
    scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    binding = OfflineSessionBinding(
        issuer: 'https://a.invalid/auth/v1',
        userId: 'owner',
        sessionId: 'sid',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    cache = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    ProjectChatServerCache.qaInstance = cache;
    final ticket = (await cache.begin('chat'))!;
    final message = Message.fromJson({
      'id': 'message',
      'chat_id': 'chat',
      'author_id': 'owner',
      'content': 'Привет',
      'created_at': now.toIso8601String()
    });
    expect(
        await cache.saveServerPage(ticket, [message], hasMore: false), isTrue);
    expectedPayload = (await db.query('chat_server_snapshot',
            where: 'chat=?', whereArgs: ['chat']))
        .single['payload'] as String;
    caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
  });
  tearDown(() async {
    ProjectChatServerCache.qaInstance = null;
    caps.dispose();
    scope.dispose();
    await events.close();
    if (db.isOpen) await closeProjectChatServerDatabase(db);
    if (dir.parent.absolute.path == Directory.systemTemp.absolute.path)
      await dir.delete(recursive: true);
  });
  test(
      'exact owner only, utf8 logical bytes, blocked/corrupt fail closed without writes',
      () async {
    for (final pair in [('other', 'sid'), ('owner', 'different')]) {
      await db.insert('chat_server_snapshot', {
        'project': 'https://a.invalid',
        'uid': pair.$1,
        'sid': pair.$2,
        'chat': 'other',
        'payload': expectedPayload
      });
      await db.insert('chat_server_attempt', {
        'project': 'https://a.invalid',
        'uid': pair.$1,
        'sid': pair.$2,
        'chat': 'other',
        'seq': 1,
        'blocked': 0
      });
      await db.insert('chat_snapshot_access', {
        'project': 'https://a.invalid',
        'uid': pair.$1,
        'sid': pair.$2,
        'chat': 'other',
        'access_ms': 0
      });
    }
    final before = await db.query('chat_server_snapshot');
    final ownerBytes =
        await cache.readScopedLogicalHistory(caps, isCurrent: () => true);
    expect(ownerBytes, utf8.encode(expectedPayload).length);
    expect(await db.query('chat_server_snapshot'), before);
    await db.update('chat_server_attempt', {'blocked': 1},
        where: 'chat=?', whereArgs: ['chat']);
    expect(
        await cache.readScopedLogicalHistory(caps, isCurrent: () => true), 0);
    await db.update('chat_server_attempt', {'blocked': 0},
        where: 'chat=?', whereArgs: ['chat']);
    await db.update('chat_server_snapshot', {'payload': '[{}]'},
        where: 'chat=?', whereArgs: ['chat']);
    expect(await cache.readScopedLogicalHistory(caps, isCurrent: () => true),
        isNull);
  });
  test('A to B to A invalidates the pending owner result', () async {
    final original = session,
        entered = Completer<void>(),
        gate = Completer<void>();
    cache.debugBeforeLogicalHistoryQuery = () async {
      entered.complete();
      await gate.future;
    };
    final pending = cache.readScopedLogicalHistory(caps, isCurrent: () => true);
    await entered.future;
    session = fakeSession('other');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = original;
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    gate.complete();
    expect(await pending, isNull);
  });
  test('oversized row set is unknown instead of truncated', () async {
    final batch = db.batch();
    for (var i = 0; i < 128; i++) {
      final chat = 'extra_$i';
      batch.insert('chat_server_snapshot', {
        'project': 'https://a.invalid',
        'uid': 'owner',
        'sid': 'sid',
        'chat': chat,
        'payload': '[]'
      });
      batch.insert('chat_server_attempt', {
        'project': 'https://a.invalid',
        'uid': 'owner',
        'sid': 'sid',
        'chat': chat,
        'seq': 1,
        'blocked': 0
      });
      batch.insert('chat_snapshot_access', {
        'project': 'https://a.invalid',
        'uid': 'owner',
        'sid': 'sid',
        'chat': chat,
        'access_ms': 0
      });
    }
    await batch.commit(noResult: true);
    expect(await cache.readScopedLogicalHistory(caps, isCurrent: () => true),
        isNull);
  });
  test('block and replacement during pending read invalidate result', () async {
    final entered = Completer<void>(), gate = Completer<void>();
    cache.debugBeforeLogicalHistoryQuery = () async {
      entered.complete();
      await gate.future;
    };
    final pending = cache.readScopedLogicalHistory(caps, isCurrent: () => true);
    await entered.future;
    caps.block();
    gate.complete();
    expect(await pending, isNull);
    cache.debugBeforeLogicalHistoryQuery = null;
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    final replacement = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    ProjectChatServerCache.qaInstance = replacement;
    expect(await cache.readScopedLogicalHistory(caps, isCurrent: () => true),
        isNull);
  });
  test('same-owner cache replacement during delayed read drops the old result',
      () async {
    final entered = Completer<void>(), gate = Completer<void>();
    cache.debugBeforeLogicalHistoryQuery = () async {
      entered.complete();
      await gate.future;
    };
    final pending = cache.readScopedLogicalHistory(caps, isCurrent: () => true);
    await entered.future;
    ProjectChatServerCache.qaInstance = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    gate.complete();
    expect(await pending, isNull);
  });
  test('SID change and database close both invalidate delayed reads', () async {
    var entered = Completer<void>(), gate = Completer<void>();
    cache.debugBeforeLogicalHistoryQuery = () async {
      entered.complete();
      await gate.future;
    };
    final sidRead = cache.readScopedLogicalHistory(caps, isCurrent: () => true);
    await entered.future;
    final original = binding;
    binding = OfflineSessionBinding(
        issuer: original.issuer,
        userId: original.userId,
        sessionId: 'different',
        notBefore: original.notBefore,
        expiresAt: original.expiresAt);
    gate.complete();
    expect(await sidRead, isNull);
    binding = original;
    entered = Completer<void>();
    gate = Completer<void>();
    final closedRead =
        cache.readScopedLogicalHistory(caps, isCurrent: () => true);
    await entered.future;
    await closeProjectChatServerDatabase(db);
    gate.complete();
    expect(await closedRead, isNull);
  });
  test('reassigning identical cache does not notify', () {
    var calls = 0;
    void listener() {
      calls++;
    }

    ProjectChatServerCache.instanceChanges.addListener(listener);
    ProjectChatServerCache.qaInstance = cache;
    expect(calls, 0);
    ProjectChatServerCache.instanceChanges.removeListener(listener);
  });
  testWidgets('shown owner value disappears when cache instance changes',
      (tester) async {
    final snapshot = InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []);
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
            measure: () async => snapshot, debugCapabilities: caps)));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    expect(find.text('Логический размер подтверждённой части истории: 0.0 МБ'),
        findsOneWidget);
    ProjectChatServerCache.qaInstance = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    await tester.pump();
    expect(
        find.text('Логический размер подтверждённой части истории: неизвестно'),
        findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
  testWidgets('timed out read never publishes its late result', (tester) async {
    final gate = Completer<void>();
    cache.debugBeforeLogicalHistoryQuery = () => gate.future;
    final snapshot = InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []);
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
            measure: () async => snapshot,
            debugCapabilities: caps,
            timeout: const Duration(milliseconds: 50))));
    await tester.pump(const Duration(milliseconds: 100));
    gate.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    expect(
        find.text('Логический размер подтверждённой части истории: неизвестно'),
        findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
  testWidgets('capability block hides an already shown value', (tester) async {
    final snapshot = InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []);
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
            measure: () async => snapshot, debugCapabilities: caps)));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    expect(find.text('Логический размер подтверждённой части истории: 0.0 МБ'),
        findsOneWidget);
    caps.block();
    await tester.pump();
    expect(
        find.text('Логический размер подтверждённой части истории: неизвестно'),
        findsOneWidget);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
  });
  testWidgets('late result after dispose is ignored', (tester) async {
    final gate = Completer<void>();
    cache.debugBeforeLogicalHistoryQuery = () => gate.future;
    final snapshot = InventorySnapshot(
        startedAt: DateTime.now(),
        finishedAt: DateTime.now(),
        observations: []);
    await tester.pumpWidget(MaterialApp(
        home: CacheDiagnosticsScreen(
            measure: () async => snapshot, debugCapabilities: caps)));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
