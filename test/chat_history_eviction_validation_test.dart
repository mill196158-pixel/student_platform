import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/core/ordinary_history_maintenance.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

class _FixedCollector extends CacheInventoryCollector {
  _FixedCollector(this.snapshot) : super(temporaryRoot: () async => Directory('.'),
    databaseRoot: () async => Directory('.'), supportRoot: () async => Directory('.'));
  final InventorySnapshot snapshot;
  @override
  Future<InventorySnapshot> collect() async => snapshot;
  @override
  Duration? ageOf(InventorySnapshot snapshot) => Duration.zero;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('coordinator needs online probe and current permit before maintenance', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('history-coordinator-');
    final temp = Directory('${dir.path}/temp'); await temp.create();
    await File('${temp.path}/optional').writeAsBytes(List.filled(100, 0));
    final db = await openProjectChatServerDatabase('${dir.path}/history.db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    final auth = caps.beginAuthorization(scope.capture()!)!;
    expect(caps.grant(SessionCapabilityMode.online, auth), isTrue);
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1', userId: 'owner',
      sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope, currentBinding: () => binding, project: 'https://a.invalid');
    final ticket = (await cache.begin('chat'))!;
    final message = Message.fromJson({'id': 'm', 'chat_id': 'chat', 'author_id': 'owner',
      'content': 'hello', 'created_at': now.toIso8601String()});
    expect(await cache.saveServerPage(ticket, [message], hasMore: false), isTrue);
    final budget = OptionalImageCacheBudget(roots: () async => [temp], limitBytes: 100);
    var online = false;
    final maintenance = OrdinaryHistoryMaintenance(cache: cache, capabilities: caps,
      budget: budget, probeOnline: () async => online, isCurrent: () => true);
    expect(await maintenance.run(), isNull);
    expect(await db.query('chat_server_snapshot'), hasLength(1));
    final delayedProbe = Completer<bool>();
    var hostCurrent = true;
    final delayed = OrdinaryHistoryMaintenance(cache: cache, capabilities: caps,
      budget: budget, probeOnline: () => delayedProbe.future, isCurrent: () => hostCurrent);
    final pending = delayed.run();
    hostCurrent = false; delayedProbe.complete(true);
    expect(await pending, isNull);
    expect(await db.query('chat_server_snapshot'), hasLength(1));
    caps.block();
    expect(caps.grant(SessionCapabilityMode.online,
      caps.beginAuthorization(scope.capture()!)!), isTrue);
    online = true;
    final entered = Completer<void>(), resume = Completer<void>();
    cache.debugBeforeHistoryEvictCommit = () async { entered.complete(); await resume.future; };
    final stale = maintenance.run();
    await entered.future;
    budget.refreshAfterCollection();
    resume.complete();
    expect(await stale, isNull);
    expect(await db.query('chat_server_snapshot'), hasLength(1));
    cache.debugBeforeHistoryEvictCommit = null;
    final snapshot = InventorySnapshot(startedAt: now, finishedAt: now, observations: [
      const InventoryObservation('public_news_blobs_v2', InventoryClass.optional, 250000000),
      for (final name in ['public_news_index_v2.db', 'news_images_v1',
        'guest_news_images_v1', 'content_media_images_v1'])
        InventoryObservation(name, InventoryClass.serverCopiesUnverified, 0),
    ]);
    final policyBudget = OptionalImageCacheBudget(collector: _FixedCollector(snapshot),
      persistPolicy: true, serviceReserveBytes: 0);
    await policyBudget.waitForPolicy();
    expect(await policyBudget.setLimit(1000000000), isTrue);
    final policyMaintenance = OrdinaryHistoryMaintenance(cache: cache, capabilities: caps,
      budget: policyBudget, probeOnline: () async => true, isCurrent: () => true);
    expect(await policyMaintenance.run(), 0);
    expect(await db.query('chat_server_snapshot'), hasLength(1));
    expect(await policyBudget.setLimit(250000000), isTrue);
    expect(await policyMaintenance.run(), greaterThan(0));
    expect(await db.query('chat_server_snapshot'), isEmpty);
    caps.block();
    expect(await maintenance.run(), isNull);
    caps.dispose(); scope.dispose(); await events.close();
    await closeProjectChatServerDatabase(db); await dir.delete(recursive: true);
  });

  test('ordinary maintenance requires live DB owner and limits each pass', () async {
    final dir = await Directory.systemTemp.createTemp('history-bounded-');
    final db = await openProjectChatServerDatabase('${dir.path}/history.db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1', userId: 'owner',
      sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)), expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope, currentBinding: () => binding, project: 'https://a.invalid');
    for (var i = 0; i < 10; i++) {
      final chat = 'c$i';
      final ticket = (await cache.begin(chat))!;
      final message = Message.fromJson({'id': 'm$i', 'chat_id': chat, 'author_id': 'owner',
        'content': 'hello', 'created_at': now.toIso8601String()});
      expect(await cache.saveServerPage(ticket, [message], hasMore: false), isTrue);
    }
    final owner = captureProjectDatabaseOwner(db)!;
    for (var i = 0; i < 128; i++) {
      final chat = 'invalid-${i.toString().padLeft(3, '0')}';
      await db.insert('chat_server_snapshot', {'project': 'https://a.invalid', 'uid': 'owner',
        'sid': 'sid', 'chat': chat, 'payload': '{bad'});
      await db.insert('chat_snapshot_access', {'project': 'https://a.invalid', 'uid': 'owner',
        'sid': 'sid', 'chat': chat, 'access_ms': 0});
    }
    await db.insert('chat_server_snapshot', {'project': 'https://a.invalid', 'uid': 'owner',
      'sid': 'sid', 'chat': 'huge', 'payload': 'x' * (4 * 1024 * 1024 + 1)});
    await db.insert('chat_snapshot_access', {'project': 'https://a.invalid', 'uid': 'owner',
      'sid': 'sid', 'chat': 'huge', 'access_ms': -1});
    final fetched = <String>[];
    cache.debugHistoryPayloadFetch = fetched.add;
    final boundedScan = (await cache.beginOrdinaryHistoryMaintenance(10000000, owner, () => true))!;
    expect(boundedScan.logicalBytesEvicted, 0);
    expect(fetched, hasLength(127));
    expect(fetched, isNot(contains('huge')));
    expect(fetched, isNot(contains('invalid-127')));
    await cache.releaseHistoryAppGuard(boundedScan);
    cache.debugHistoryPayloadFetch = null;
    await db.delete('chat_server_snapshot', where: "chat LIKE 'invalid-%' OR chat='huge'");
    await db.delete('chat_snapshot_access', where: "chat LIKE 'invalid-%' OR chat='huge'");
    expect(await cache.beginOrdinaryHistoryMaintenance(10000000, owner, () => false), isNull);
    expect(await db.query('chat_server_snapshot'), hasLength(10));
    final tooSmall = (await cache.beginOrdinaryHistoryMaintenance(1, owner, () => true))!;
    expect(tooSmall.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(tooSmall);
    var current = true;
    final entered = Completer<void>(), resume = Completer<void>();
    cache.debugBeforeHistoryEvictCommit = () async { entered.complete(); await resume.future; };
    final stalePass = cache.beginOrdinaryHistoryMaintenance(10000000, owner, () => current);
    await entered.future;
    current = false; resume.complete();
    expect(await stalePass, isNull);
    expect(await db.query('chat_server_snapshot'), hasLength(10));
    cache.debugBeforeHistoryEvictCommit = null;
    final below = (await cache.beginOrdinaryBudgetMaintenance(owner, knownOptionalCost: 0,
      budgetLimit: 10000000, observationAndOnlineCurrent: () => true))!;
    expect(below.logicalBytesEvicted, 0);
    await cache.releaseHistoryAppGuard(below);
    final guard = (await cache.beginOrdinaryBudgetMaintenance(owner, knownOptionalCost: 10000000,
      budgetLimit: 10000000, observationAndOnlineCurrent: () => true))!;
    expect(guard.logicalBytesEvicted, greaterThan(0));
    expect(await db.query('chat_server_snapshot'), hasLength(2));
    await cache.releaseHistoryAppGuard(guard);
    await closeProjectChatServerDatabase(db);
    expect(await cache.beginOrdinaryHistoryMaintenance(100, owner, () => true), isNull);
    scope.dispose(); await events.close(); await dir.delete(recursive: true);
  });

  test('LRU only removes fully confirmed snapshots and retains unknown rows', () async {
    final dir = await Directory.systemTemp.createTemp('history-validation-');
    final db = await openProjectChatServerDatabase('${dir.path}/history.db', factory: databaseFactoryFfi);
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('owner');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(issuer: 'https://a.invalid/auth/v1', userId: 'owner',
      sessionId: 'sid', notBefore: now.subtract(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 1)));
    final cache = ProjectChatServerCache(db: db, scope: scope,
      currentBinding: () => binding, project: 'https://a.invalid');
    Map<String, dynamic> message(String chat) => Message.fromJson({
      'id': 'server-id', 'chat_id': chat, 'author_id': 'owner',
      'content': 'hello', 'created_at': now.toIso8601String(),
    }).toJson();
    final payloads = <String, String>{
      'valid': jsonEncode([message('valid')]),
      'active': jsonEncode([message('active')]),
      'mixed': jsonEncode([message('mixed'), {...message('mixed'), 'delivery_status': 'sending'}]),
      'failed': jsonEncode([{...message('failed'), 'delivery_status': 'failed'}]),
      'client': jsonEncode([{...message('client'), 'client_id': 'pending'}]),
      'path': jsonEncode([{...message('path'), 'imagePath': '/local/image'}]),
      'outbound': jsonEncode([{...message('outbound'), 'outbound_file_ids': ['file']}]),
      'wrongchat': jsonEncode([message('other')]),
      'corrupt': '{broken',
      'missing': jsonEncode([message('missing')]),
      'blocked': jsonEncode([message('blocked')]),
      'max': jsonEncode([message('max')]),
      'blankid': jsonEncode([{...message('blankid'), 'id': '  '}]),
    };
    for (final e in payloads.entries) {
      await db.insert('chat_server_snapshot', {'project': 'https://a.invalid', 'uid': 'owner',
        'sid': 'sid', 'chat': e.key, 'payload': e.value});
      await db.insert('chat_snapshot_access', {'project': 'https://a.invalid', 'uid': 'owner',
        'sid': 'sid', 'chat': e.key, 'access_ms': 1});
      if (e.key != 'missing') {
        await db.insert('chat_server_attempt', {'project': 'https://a.invalid', 'uid': 'owner',
          'sid': 'sid', 'chat': e.key, 'seq': e.key == 'max' ? 9223372036854775807 : 1,
          'blocked': e.key == 'blocked' ? 1 : 0});
      }
    }
    final oldTicket = (await cache.begin('valid'))!;
    final lease = (await cache.acquireHistoryRouteLease('active'))!;
    final known = utf8.encode(payloads['valid']!).length + utf8.encode(payloads['active']!).length;
    final safeBudget = (await cache.beginOrdinaryBudgetMaintenance(captureProjectDatabaseOwner(db)!,
      knownOptionalCost: 10000, budgetLimit: 10000 + known + 1,
      observationAndOnlineCurrent: () => true))!;
    expect(safeBudget.logicalBytesEvicted, 0);
    expect(await db.query('chat_server_snapshot'), hasLength(payloads.length));
    await cache.releaseHistoryAppGuard(safeBudget);
    final guard = (await cache.beginHistoryAppGuard(1000000, allEnginesGuarded: true))!;
    expect(guard.logicalBytesEvicted, utf8.encode(payloads['valid']!).length);
    final snapshots = await db.query('chat_server_snapshot', columns: ['chat']);
    final access = await db.query('chat_snapshot_access', columns: ['chat']);
    final expected = payloads.keys.toSet()..remove('valid');
    expect(snapshots.map((r) => r['chat']).toSet(), expected);
    expect(access.map((r) => r['chat']).toSet(), expected);
    final freshMessage = Message.fromJson(message('valid'));
    expect(await cache.saveServerPage(oldTicket, [freshMessage], hasMore: false), isFalse);
    final newTicket = (await cache.begin('valid'))!;
    expect(await cache.saveServerPage(newTicket, [freshMessage], hasMore: false), isTrue);
    await cache.releaseHistoryAppGuard(guard);
    await cache.releaseHistoryRouteLease(lease);
    await closeProjectChatServerDatabase(db);
    scope.dispose(); await events.close(); await dir.delete(recursive: true);
  });
}
