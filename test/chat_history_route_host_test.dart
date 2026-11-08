import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/core/ordinary_history_maintenance_host.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/chat_history_route_host.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

class _DelayedCache extends ProjectChatServerCache {
  _DelayedCache({required super.db, required super.scope,
    required super.currentBinding, required super.project});
  final resume = Completer<void>();
  final released = Completer<void>();
  @override
  Future<ChatHistoryRouteLease?> acquireHistoryRouteLease(String chat) async {
    await resume.future;
    return super.acquireHistoryRouteLease(chat);
  }
  @override
  Future<void> releaseHistoryRouteLease(ChatHistoryRouteLease lease) async {
    await super.releaseHistoryRouteLease(lease);
    if (!released.isCompleted) released.complete();
  }
}

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHold implements HistoryRouteHold {
  final done = Completer<void>();
  bool closed = false;
  @override
  Future<void> get ready => done.future;
  @override
  Future<void> close() async { closed = true; }
}

class _StatefulComposer extends StatefulWidget {
  const _StatefulComposer(this.onCreate);
  final void Function() onCreate;
  @override
  State<_StatefulComposer> createState() => _StatefulComposerState();
}
class _StatefulComposerState extends State<_StatefulComposer> {
  @override
  void initState() { super.initState(); widget.onCreate(); }
  @override
  Widget build(BuildContext context) => const Text('composer');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('maintenance host never delays child and cancels on disposal', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final cache = ProjectChatServerCache(db: _UnusedDatabase(), scope: scope,
      currentBinding: () => null, project: 'https://a.invalid');
    final budget = OptionalImageCacheBudget(roots: () async => []);
    var starts = 0;
    Widget host([bool allowed = true]) => MaterialApp(home: OrdinaryHistoryMaintenanceHost(cache: cache,
      capabilities: caps, budget: budget, probeOnline: () async => false,
      isCurrent: () => allowed, debugOnStart: () => starts++, child: const Text('home')));
    await tester.pumpWidget(host());
    expect(find.text('home'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4)); expect(starts, 0);
    await tester.pump(const Duration(seconds: 1)); expect(starts, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host());
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(host(false));
    await tester.pump(const Duration(seconds: 2)); expect(starts, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6)); expect(starts, 1);
    caps.dispose(); scope.dispose(); await events.close();
  });

  testWidgets('late old hold does not disturb the replacement route', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    OfflineSessionBinding binding(String uid) => OfflineSessionBinding(
      issuer: 'https://a.invalid/auth/v1', userId: uid, sessionId: 'sid-$uid',
      notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    var currentBinding = binding('a');
    final cache = ProjectChatServerCache(db: _UnusedDatabase(), scope: scope,
      currentBinding: () => currentBinding, project: 'https://a.invalid');
    final holds = <_FakeHold>[];
    await tester.pumpWidget(MaterialApp(home: ChatHistoryRouteHost(cache: cache,
      debugCreateHold: (_) { final h = _FakeHold(); holds.add(h); return h; },
      child: const Text('chat ready'))));
    session = fakeSession('b'); currentBinding = binding('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session)); await tester.pump();
    holds.last.done.complete(); await tester.pump();
    expect(find.text('chat ready'), findsOneWidget);
    session = fakeSession('c'); currentBinding = binding('c');
    holds.first.done.complete(); await tester.pump();
    expect(holds.length, 2);
    expect(holds.last.closed, isFalse);
    await tester.pumpWidget(const SizedBox()); scope.dispose(); await events.close();
  });

  testWidgets('late hold never mounts previous owner before auth event', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    OfflineSessionBinding binding(String uid) => OfflineSessionBinding(
      issuer: 'https://a.invalid/auth/v1', userId: uid, sessionId: 'sid-$uid',
      notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    var currentBinding = binding('a');
    final cache = ProjectChatServerCache(db: _UnusedDatabase(), scope: scope,
      currentBinding: () => currentBinding, project: 'https://a.invalid');
    final hold = _FakeHold(); var created = 0;
    await tester.pumpWidget(MaterialApp(home: ChatHistoryRouteHost(cache: cache,
      debugCreateHold: (_) => hold, child: _StatefulComposer(() => created++))));
    session = fakeSession('b'); currentBinding = binding('b');
    hold.done.complete(); await tester.pump();
    expect(created, 0);
    expect(find.text('composer'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    scope.dispose(); await events.close();
  });

  testWidgets('binding changes before auth event hide the old composer', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    OfflineSessionBinding binding(String uid, String sid) => OfflineSessionBinding(
      issuer: 'https://a.invalid/auth/v1', userId: uid, sessionId: sid,
      notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    var currentBinding = binding('a', 'one');
    final cache = ProjectChatServerCache(db: _UnusedDatabase(), scope: scope,
      currentBinding: () => currentBinding, project: 'https://a.invalid');
    final holds = <_FakeHold>[];
    var created = 0;
    Widget screen() => MaterialApp(home: ChatHistoryRouteHost(cache: cache,
      debugCreateHold: (_) { final h = _FakeHold(); holds.add(h); return h; },
      child: _StatefulComposer(() => created++)));
    await tester.pumpWidget(screen());
    holds.last.done.complete(); await tester.pump();
    expect(created, 1);
    session = fakeSession('a', access: 'refreshed');
    await tester.pumpWidget(screen());
    expect(find.text('composer'), findsOneWidget);
    expect(created, 1);
    currentBinding = binding('a', 'two');
    await tester.pumpWidget(screen());
    expect(find.text('composer'), findsNothing);
    session = fakeSession('b');
    currentBinding = binding('b', 'three');
    await tester.pumpWidget(screen());
    expect(find.text('composer'), findsNothing);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    holds.last.done.complete(); await tester.pump();
    expect(find.text('composer'), findsOneWidget);
    expect(created, 2);
    await tester.pumpWidget(const SizedBox());
    scope.dispose(); await events.close();
  });

  testWidgets('waits for hold and replaces subtree only after account change', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    OfflineSessionBinding binding(String uid) => OfflineSessionBinding(
      issuer: 'https://a.invalid/auth/v1', userId: uid, sessionId: 'sid-$uid',
      notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    var currentBinding = binding('a');
    final cache = ProjectChatServerCache(db: _UnusedDatabase(), scope: scope,
      currentBinding: () => currentBinding, project: 'https://a.invalid');
    final holds = <_FakeHold>[];
    await tester.pumpWidget(MaterialApp(home: ChatHistoryRouteHost(cache: cache,
      debugCreateHold: (_) { final h = _FakeHold(); holds.add(h); return h; },
      child: const Text('chat ready'))));
    expect(find.text('chat ready'), findsNothing);
    holds.single.done.complete();
    await tester.pump();
    expect(find.text('chat ready'), findsOneWidget);
    session = fakeSession('a', access: 'new');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await tester.pump();
    expect(holds.length, 1);
    expect(find.text('chat ready'), findsOneWidget);
    session = fakeSession('b');
    currentBinding = binding('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    expect(holds.length, 2);
    expect(holds.first.closed, isTrue);
    expect(find.text('chat ready'), findsNothing);
    holds.last.done.complete();
    await tester.pump();
    expect(find.text('chat ready'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(holds.last.closed, isTrue);
    scope.dispose();
    await events.close();
  });

  test('hung acquisition settles readiness and releases its late lease', () async {
    final dir = await Directory.systemTemp.createTemp('chat-route-hold-');
    final db = await openProjectChatServerDatabase('${dir.path}/history.db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1', userId: 'owner',
      sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final cache = _DelayedCache(db: db, scope: scope, currentBinding: () => binding,
      project: 'https://a.invalid');
    final hold = ChatHistoryRouteHold(cache);
    await hold.ready.timeout(const Duration(seconds: 2));
    cache.resume.complete();
    await cache.released.future.timeout(const Duration(seconds: 5));
    final rows = await db.query('chat_route_leases');
    expect(rows, isEmpty);
    await hold.close();
    await closeProjectChatServerDatabase(db);
    scope.dispose();
    await events.close();
    await dir.delete(recursive: true);
  });
}
