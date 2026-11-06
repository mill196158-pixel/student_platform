import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Db implements Database, Transaction {
  final rows = <String, Map<String, Object?>>{};
  final attempts = <String, Map<String, Object?>>{};
  Future<void> Function()? beforeInsert;
  String key(List<Object?> a) => a.join('|');
  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) async {
    final before = Map<String, Map<String, Object?>>.from(rows);
    final beforeAttempts = {
      for (final e in attempts.entries) e.key: Map<String, Object?>.of(e.value)
    };
    try {
      return await action(this);
    } catch (_) {
      rows
        ..clear()
        ..addAll(before);
      attempts
        ..clear()
        ..addAll(beforeAttempts);
      rethrow;
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    final row =
        (table == 'chat_server_attempt' ? attempts : rows)[key(whereArgs!)];
    return row == null ? [] : [row];
  }

  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) async {
    final k =
        key([values['project'], values['uid'], values['sid'], values['chat']]);
    if (table == 'chat_server_attempt') {
      attempts.putIfAbsent(k, () => {...values, 'blocked': 0});
    } else {
      await beforeInsert?.call();
      rows[k] = Map.of(values);
    }
    return 1;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    final row = attempts[key(arguments!)]!;
    row['seq'] = (row['seq'] as int) + 1;
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('server pages remain bound to project, session and deletion', () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.now().toUtc();
    final binding = OfflineSessionBinding(
        issuer: 'https://a.invalid/auth/v1',
        userId: 'a',
        sessionId: 'sid',
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    final db = _Db();
    final cache = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://a.invalid');
    Message message(String id, int hour) => Message.fromJson({
          'id': id,
          'chat_id': 'chat',
          'author_id': 'a',
          'content': id,
          'created_at': DateTime.utc(2026, 1, 1, hour).toIso8601String()
        });
    final stale = (await cache.begin('chat'))!;
    final latest = (await cache.begin('chat'))!;
    expect(
        await cache.saveServerPage(stale, [message('stale', 1)],
            hasMore: false),
        isFalse);
    expect(
        await cache.saveServerPage(
            latest, [message('old', 1), message('deleted', 2)],
            hasMore: false),
        isTrue);
    expect(
        await cache.saveServerPage(
            (await cache.begin('chat'))!, [message('new', 3)],
            hasMore: false),
        isTrue);
    final cap = SessionCapabilities(scope);
    expect(
        cap.grant(SessionCapabilityMode.cacheOnly,
            cap.beginAuthorization(scope.capture()!)!),
        isTrue);
    expect((await cache.read('chat', cap))!.map((m) => m.id), ['new']);
    expect(await cache.readForOnlinePrewarm('chat', cap), isNull);
    expect(cap.grant(SessionCapabilityMode.online,
        cap.beginAuthorization(scope.capture()!)!), isTrue);
    expect((await cache.readForOnlinePrewarm('chat', cap))!.map((m) => m.id), ['new']);
    expect(await cache.read('chat', cap), isNull);
    final otherEvents = StreamController<AuthState>.broadcast(sync: true);
    final otherScope = AuthSessionScope(currentSession: () => session, authEvents: otherEvents.stream);
    otherEvents.add(AuthState(AuthChangeEvent.initialSession, session));
    final otherCap = SessionCapabilities(otherScope);
    expect(otherCap.grant(SessionCapabilityMode.online,
        otherCap.beginAuthorization(otherScope.capture()!)!), isTrue);
    expect(await cache.readForOnlinePrewarm('chat', otherCap), isNull);
    otherCap.dispose();
    otherScope.dispose();
    await otherEvents.close();
    final other = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'https://b.invalid');
    expect(await other.readForOnlinePrewarm('chat', cap), isNull);
    final entered = Completer<void>();
    final resume = Completer<void>();
    db.beforeInsert = () async {
      entered.complete();
      await resume.future;
    };
    final pending = cache.saveServerPage(
        (await cache.begin('chat'))!, [message('stale', 4)],
        hasMore: false);
    await entered.future;
    scope.invalidateForSignOut();
    resume.complete();
    expect(await pending, isFalse);
    expect(db.rows.values.single['payload'].toString(), contains('new'));

    expect(await cache.read('chat', cap), isNull);
    cap.dispose();
    scope.dispose();
    await events.close();
  });
}
