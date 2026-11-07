import 'dart:async';
import 'dart:io';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'dart:isolate';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/startup_cache_budget.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/immutable_message_snapshot.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

Future<void> leaseWorker((String, SendPort) args) async {
  sqfliteFfiInit();
  final db = await openProjectChatServerDatabase(args.$1, factory: databaseFactoryFfi);
  final port = ReceivePort();
  args.$2.send(port.sendPort);
  await db.transaction((txn) async {
    await txn.insert('chat_route_leases', {'token': 'second-route',
      'project': 'https://a.invalid', 'uid': 'owner', 'sid': 'sid', 'chat': 'newer',
      'database_token': debugProjectChatDatabaseGuard(db)!});
    args.$2.send('entered');
    await port.first;
  });
  port.close();
  final closePort = ReceivePort();
  args.$2.send(closePort.sendPort);
  await closePort.first;
  closePort.close();
  await closeProjectChatServerDatabase(db);
  args.$2.send('done');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('handle cannot close around a late denial or admit new checks after close', () async {
    final dir = await Directory.systemTemp.createTemp('fence-close-test-');
    final path = '${dir.path}/history.db';
    final oldDb = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    final newDb = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    final old = PinnedAccessFence(oldDb, databaseToken: debugProjectChatDatabaseGuard(oldDb));
    final fresh = PinnedAccessFence(newDb, databaseToken: debugProjectChatDatabaseGuard(newDb));
    const p = 'https://a.invalid', u = 'owner', k = 'file';
    final pending = await old.begin(p, u, k);
    await expectLater(oldDb.close(), throwsStateError);
    final newAllow = await fresh.begin(p, u, k);
    await fresh.finish(newAllow, allowed: true);
    expect(await fresh.canRead(p, u, k), isFalse);
    await old.finish(pending, allowed: false);
    await oldDb.close();
    expect(await fresh.canRead(p, u, k), isFalse);
    final retry = await fresh.begin(p, u, k);
    await fresh.finish(retry, allowed: true);
    expect(await fresh.canRead(p, u, k), isTrue);
    await newDb.close();
    await dir.delete(recursive: true);
  });

  test('LRU protects active and crash-stale leases and leaves unsent/attempts intact', () async {
    final dir = await Directory.systemTemp.createTemp('history-quota-');
    final path = '${dir.path}/history.db';
    var db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1',
        userId: 'owner', sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    var cache = ProjectChatServerCache(db: db, scope: scope,
        currentBinding: () => binding, project: 'https://a.invalid');
    SharedPreferences.setMockInitialValues({'global_draft_texts': 'unsent'});
    addTearDown(() async {
      await closeProjectChatServerDatabase(db);
      scope.dispose();
      await events.close();
      if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await dir.delete(recursive: true);
      }
    });
    for (final chat in ['active', 'older', 'newer']) {
      final ticket = (await cache.begin(chat))!;
      final message = Message.fromJson({'id': '$chat-message', 'chat_id': chat,
        'author_id': 'owner', 'content': chat, 'created_at': now.toIso8601String()});
      expect(await cache.saveServerPage(ticket, [message], hasMore: false), isTrue);
    }
    // Unknown legacy snapshots have no quota metadata and are not candidates.
    await db.insert('chat_server_snapshot', {'project': 'https://a.invalid',
      'uid': 'owner', 'sid': 'sid', 'chat': 'legacy', 'payload': '[]'});
    await db.insert('chat_server_snapshot', {'project': 'https://a.invalid',
      'uid': 'other', 'sid': 'sid', 'chat': 'other-owner', 'payload': '[]'});
    await db.insert('chat_snapshot_access', {'project': 'https://a.invalid',
      'uid': 'other', 'sid': 'sid', 'chat': 'other-owner', 'access_ms': 0});
    await db.insert('chat_server_snapshot', {'project': 'https://a.invalid',
      'uid': 'owner', 'sid': 'different-sid', 'chat': 'other-session', 'payload': '[]'});
    await db.insert('chat_snapshot_access', {'project': 'https://a.invalid',
      'uid': 'owner', 'sid': 'different-sid', 'chat': 'other-session', 'access_ms': 0});
    await db.rawUpdate("UPDATE chat_snapshot_access SET access_ms=1 WHERE chat='older'");
    await db.rawUpdate("UPDATE chat_snapshot_access SET access_ms=2 WHERE chat='active'");
    await db.rawUpdate("UPDATE chat_snapshot_access SET access_ms=3 WHERE chat='newer'");
    final wildcard = ChatHistoryRouteHold(cache);
    await wildcard.ready;
    final whileVisible = (await cache.beginHistoryAppGuard(1000000, allEnginesGuarded: true))!;
    expect(whileVisible.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(whileVisible);
    await wildcard.close();
    final failedHold = ChatHistoryRouteHold(null);
    await failedHold.ready;
    final afterFailure = (await cache.beginHistoryAppGuard(1000000, allEnginesGuarded: true))!;
    expect(afterFailure.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(afterFailure);
    await failedHold.close();
    final lease = (await cache.acquireHistoryRouteLease('active'))!;
    final receive = ReceivePort();
    final entered = Completer<void>(), committed = Completer<void>(), completed = Completer<void>();
    late SendPort release, closeWorker;
    var ports = 0;
    receive.listen((event) {
      if (event is SendPort) {
        if (ports++ == 0) { release = event; } else { closeWorker = event; committed.complete(); }
      }
      if (event == 'entered') entered.complete();
      if (event == 'done') completed.complete();
    });
    await Isolate.spawn(leaseWorker, (path, receive.sendPort));
    await entered.future.timeout(const Duration(seconds: 8));
    var evicted = false;
    final evict = cache.beginHistoryAppGuard(1, allEnginesGuarded: true)
        .then((value) { evicted = true; return value; });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(evicted, isFalse);
    release.send('release');
    await committed.future.timeout(const Duration(seconds: 8));
    final blockedGuard = (await evict)!;
    expect(blockedGuard.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(blockedGuard);
    closeWorker.send('close');
    await completed.future.timeout(const Duration(seconds: 8));
    final guard = (await cache.beginHistoryAppGuard(1, allEnginesGuarded: true))!;
    expect(guard.logicalBytesEvicted, greaterThan(0));
    receive.close();
    expect((await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['older'])), isEmpty);
    expect((await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['active'])), hasLength(1));
    expect((await db.query('chat_server_attempt')), hasLength(3));
    expect((await SharedPreferences.getInstance()).getString('global_draft_texts'), 'unsent');
    final secondDb = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    final secondCache = ProjectChatServerCache(db: secondDb, scope: scope,
        currentBinding: () => binding, project: 'https://a.invalid');
    final otherGuard = (await secondCache.beginHistoryAppGuard(1000000,
        allEnginesGuarded: true))!;
    expect(otherGuard.logicalBytesEvicted, 0);
    await secondCache.releaseHistoryAppGuard(otherGuard);
    await secondCache.releaseHistoryRouteLease(lease);
    expect(await db.query('chat_route_leases'), hasLength(1));
    await closeProjectChatServerDatabase(secondDb);
    await cache.releaseHistoryAppGuard(guard);
    final staleGuard = (await cache.beginHistoryAppGuard(1000000, allEnginesGuarded: true))!;
    expect((await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['active'])), hasLength(1));
    expect((await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['legacy'])), hasLength(1));
    expect((await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['other-owner'])), hasLength(1));
    expect((await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['other-session'])), hasLength(1));
    expect((await db.rawQuery('PRAGMA user_version')).single.values.single, 3);
    final secondEngine = (await cache.beginHistoryAppGuard(1000000, allEnginesGuarded: true))!;
    expect(secondEngine.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(secondEngine);
    await db.insert('chat_server_snapshot', {'project': 'https://a.invalid',
      'uid': 'owner', 'sid': 'sid', 'chat': 'temporary-server-only',
      'payload': 'x' * 1000000});
    await db.delete('chat_server_snapshot', where: 'chat=?', whereArgs: ['temporary-server-only']);
    final compacted = await cache.compactHistory(staleGuard);
    expect(compacted, isNotNull);
    var physical = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (await file.exists()) physical += (await file.stat()).size;
    }
    expect(compacted!.afterBytes, physical);
    expect(compacted.physicallyFreedBytes, greaterThan(0));
    expect((await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['active'])), hasLength(1));
    expect((await db.query('chat_server_attempt')), hasLength(3));
    // A crashed engine leaves its guard in storage and conservatively blocks
    // cleanup across restart until an explicit recovery protocol exists.
    await debugAbandonProjectChatDatabase(db);
    db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    cache = ProjectChatServerCache(db: db, scope: scope,
        currentBinding: () => binding, project: 'https://a.invalid');
    final afterCrash = (await cache.beginHistoryAppGuard(1000000, allEnginesGuarded: true))!;
    expect(afterCrash.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(afterCrash);
    // Crash left both the app guard and its database-handle guard, while the
    // reopened handle has one new guard of its own.
    expect(await db.query('chat_app_guards'), hasLength(3));
    expect(staleGuard.logicalBytesEvicted, greaterThan(0));
  });

  test('another live process blocks eviction and its crash releases guard', () async {
    final dir = await Directory.systemTemp.createTemp('history-guard-process-');
    final path = '${dir.path}/history.db';
    final db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1',
        userId: 'owner', sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope,
        currentBinding: () => binding, project: 'https://a.invalid');
    const token = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    final dart = Platform.isWindows
        ? '${Platform.environment['FLUTTER_ROOT'] ?? 'C:/flutter'}/bin/cache/dart-sdk/bin/dart.exe'
        : 'dart';
    final marker = '${db.path}.guards/$token';
    final child = await Process.start(dart, ['test/helpers/cache_guard_child.dart', marker, token]);
    addTearDown(() async {
      child.kill();
      await child.exitCode;
      await closeProjectChatServerDatabase(db);
      scope.dispose();
      await events.close();
      if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) {
        await dir.delete(recursive: true);
      }
    });
    expect(await child.stdout.transform(utf8.decoder).transform(const LineSplitter()).first
        .timeout(const Duration(seconds: 8)), 'ready');
    await db.insert('chat_app_guards', {'token': token, 'project': '*',
      'uid': child.pid.toString(), 'sid': '', 'database_token': token});
    final childFence = PinnedAccessFence(db, databaseToken: token);
    final ownFence = PinnedAccessFence(db, databaseToken: debugProjectChatDatabaseGuard(db));
    final initialFence = await childFence.begin('https://a.invalid', 'owner', 'file');
    await childFence.finish(initialFence, allowed: true);
    await childFence.begin('https://a.invalid', 'owner', 'file');
    final liveFence = await ownFence.begin('https://a.invalid', 'owner', 'file');
    await cache.recoverDeadAccessGuards();
    expect(await db.query('pinned_fence_pending'), hasLength(2));
    await db.insert('chat_route_leases', {'token': 'child-route',
      'project': 'https://a.invalid', 'uid': 'owner', 'sid': 'sid',
      'chat': 'cached', 'database_token': token});
    await db.insert('chat_server_snapshot', {'project': 'https://a.invalid',
      'uid': 'owner', 'sid': 'sid', 'chat': 'cached', 'payload': '[]'});
    await db.insert('chat_snapshot_access', {'project': 'https://a.invalid',
      'uid': 'owner', 'sid': 'sid', 'chat': 'cached', 'access_ms': 1});
    final live = (await cache.beginHistoryAppGuard(1, allEnginesGuarded: true))!;
    expect(live.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(live);
    child.kill();
    await child.exitCode;
    final mediaSession = (await cache.openMediaProtection(dir))!;
    expect(await mediaSession.store.accessRecovery, isTrue);
    expect(await db.query('pinned_fence_pending'), hasLength(1));
    await ownFence.finish(liveFence, allowed: true);
    expect(await ownFence.canRead('https://a.invalid', 'owner', 'file'), isFalse);
    final freshFence = await ownFence.begin('https://a.invalid', 'owner', 'file');
    await ownFence.finish(freshFence, allowed: true);
    expect(await ownFence.canRead('https://a.invalid', 'owner', 'file'), isFalse);
    await db.transaction((txn) => ownFence.markPinned(txn, 'https://a.invalid', 'owner', 'file', 'synthetic-checksum'));
    expect(await ownFence.canRead('https://a.invalid', 'owner', 'file'), isTrue);
    await mediaSession.close();
    final recovered = (await cache.beginHistoryAppGuard(1, allEnginesGuarded: true))!;
    expect(recovered.logicalBytesEvicted, greaterThan(0));
    expect(await db.query('chat_route_leases'), isEmpty);
    expect(await File(marker).exists(), isTrue); // Lock files are never deleted.
    await cache.releaseHistoryAppGuard(recovered);
    const malformedToken = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';
    final malformedMarker = File('${db.path}.guards/$malformedToken');
    await malformedMarker.writeAsString('not-the-token');
    await db.insert('chat_app_guards', {'token': malformedToken, 'project': '*',
      'uid': (pid + 1000000).toString(), 'sid': '', 'database_token': malformedToken});
    final unverifiable = (await cache.beginHistoryAppGuard(1, allEnginesGuarded: true))!;
    expect(unverifiable.logicalBytesEvicted, 0);
    expect(await db.query('chat_app_guards', where: 'token=?', whereArgs: [malformedToken]), hasLength(1));
    await cache.releaseHistoryAppGuard(unverifiable);
  });

  test('startup coordinator counts proven bytes and keeps an active chat and unsent draft', () async {
    final dir = await Directory.systemTemp.createTemp('history-startup-budget-');
    final temp = Directory('${dir.path}/temp');
    await temp.create();
    final db = await openProjectChatServerDatabase('${dir.path}/history.db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1',
      userId: 'owner', sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://a.invalid');
    SharedPreferences.setMockInitialValues({'global_draft_texts': 'protected'});
    final prefs = await SharedPreferences.getInstance();
    addTearDown(() async {
      await db.close();
      scope.dispose();
      await events.close();
      if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) await dir.delete(recursive: true);
    });
    for (final chat in ['visible', 'old']) {
      final ticket = (await cache.begin(chat))!;
      final message = Message.fromJson({'id': '$chat-message', 'chat_id': chat,
        'author_id': 'owner', 'content': chat, 'created_at': now.toIso8601String()});
      expect(await cache.saveServerPage(ticket, [message], hasMore: false), isTrue);
    }
    final lease = (await cache.acquireHistoryRouteLease('visible'))!;
    expect(await runStartupCacheBudget(cache, allEnginesGuarded: false,
      root: temp, prefs: prefs, limitBytes: 1), isNull);
    final evictEntered = Completer<void>(), finishEvict = Completer<void>();
    cache.debugBeforeHistoryEvictCommit = () async { evictEntered.complete(); await finishEvict.future; };
    final racingEviction = cache.beginHistoryAppGuard(1, allEnginesGuarded: true);
    await evictEntered.future;
    final capabilities = SessionCapabilities(scope);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    expect(ScopedImmutableMessageSnapshot.capture(capabilities: capabilities,
      sourceCurrent: () => true, alreadyLoaded: []), isNull);
    final failedRoute = ChatHistoryRouteHold(null);
    var routeReady = false;
    unawaited(failedRoute.ready.then((_) => routeReady = true));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(routeReady, isFalse);
    finishEvict.complete();
    expect(await racingEviction, isNull);
    await failedRoute.ready;
    await failedRoute.close();
    capabilities.dispose();
    cache.debugBeforeHistoryEvictCommit = null;
    expect(await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['old']), hasLength(1));
    final slowInventory = Completer<int?>();
    final timedOut = await runStartupCacheBudget(cache, allEnginesGuarded: true,
      root: temp, prefs: prefs, limitBytes: 1,
      scanTimeout: const Duration(milliseconds: 30), debugMeasure: () => slowInventory.future);
    expect(timedOut, isNull);
    slowInventory.complete(1000000);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['old']), hasLength(1));
    final result = await runStartupCacheBudget(cache, allEnginesGuarded: true,
      root: temp, prefs: prefs, limitBytes: 1);
    expect(result, isNotNull);
    expect(result!.logicalHistoryBytesEvicted, greaterThan(0));
    expect(await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['visible']), hasLength(1));
    expect(await db.query('chat_server_snapshot', where: 'chat=?', whereArgs: ['old']), isEmpty);
    expect(prefs.getString('global_draft_texts'), 'protected');
    await cache.releaseHistoryRouteLease(lease);
  });

  test('lock refusal preserves cached reads and forbids eviction on every handle', () async {
    final dir = await Directory.systemTemp.createTemp('history-lock-failure-');
    final path = '${dir.path}/history.db';
    debugBeforeDatabaseGuard = () async => throw FileSystemException('lock refused');
    final db = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    debugBeforeDatabaseGuard = null;
    final other = await openProjectChatServerDatabase(path, factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1',
      userId: 'owner', sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://a.invalid');
    final otherCache = ProjectChatServerCache(db: other, scope: scope,
      currentBinding: () => binding, project: 'https://a.invalid');
    addTearDown(() async {
      debugBeforeDatabaseGuard = null;
      await db.close(); await other.close();
      scope.dispose(); await events.close();
      if (dir.parent.absolute.path == Directory.systemTemp.absolute.path) await dir.delete(recursive: true);
    });
    final ticket = (await cache.begin('chat'))!;
    final message = Message.fromJson({'id': 'server', 'chat_id': 'chat', 'author_id': 'owner',
      'content': 'available', 'created_at': now.toIso8601String()});
    expect(await cache.saveServerPage(ticket, [message], hasMore: false), isTrue);
    final capabilities = SessionCapabilities(scope);
    expect(capabilities.grant(SessionCapabilityMode.cacheOnly,
        capabilities.beginAuthorization(scope.capture()!)!), isTrue);
    expect((await cache.read('chat', capabilities))!.single.text, 'available');
    expect(await cache.beginHistoryAppGuard(1, allEnginesGuarded: true), isNull);
    final blocked = (await otherCache.beginHistoryAppGuard(1, allEnginesGuarded: true))!;
    expect(blocked.logicalBytesEvicted, 0);
    await otherCache.releaseHistoryAppGuard(blocked);
    expect((await cache.read('chat', capabilities))!.single.text, 'available');
    capabilities.dispose();
  });
}
