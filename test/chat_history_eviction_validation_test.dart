import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

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
    final guard = (await cache.beginOrdinaryHistoryMaintenance(10000000, owner, () => true))!;
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
