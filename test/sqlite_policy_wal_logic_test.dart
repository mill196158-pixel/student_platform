import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/sqlite_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

/// In-memory SQL contract double: verifies Dart fences, not SQLite durability.
class _Database implements Database, Transaction {
  Map<String, Object?>? owner;
  final grants = <String, Map<String, Object?>>{};

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
      {bool? exclusive}) async {
    final beforeOwner = owner == null ? null : Map<String, Object?>.of(owner!);
    final beforeGrants = {
      for (final entry in grants.entries)
        entry.key: Map<String, Object?>.of(entry.value)
    };
    try {
      return await action(this);
    } catch (_) {
      owner = beforeOwner;
      grants
        ..clear()
        ..addAll(beforeGrants);
      rethrow;
    }
  }

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async {
    final a = arguments!;
    if (sql.startsWith('INSERT OR IGNORE INTO policy_owner')) {
      owner ??= {'epoch': 0, 'live_seq': 0, 'state': a[2], 'last_seen': null};
    } else if (sql.startsWith('INSERT OR REPLACE INTO policy_grant')) {
      grants[a[2] as String] = {
        'owner_epoch': a[3],
        'live_seq': a[4],
        'checked_at': a[5],
        'valid_until': a[6]
      };
    } else {
      throw StateError('Unexpected insert');
    }
    return 1;
  }

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async {
    final a = arguments!;
    final row = owner!;
    if (sql.startsWith(
        "UPDATE policy_owner SET live_seq=live_seq+1,state='revoked'")) {
      row['live_seq'] = (row['live_seq'] as int) + 1;
      row['state'] = 'revoked';
    } else if (sql.startsWith('UPDATE policy_owner SET state=?,last_seen=?')) {
      if (row['epoch'] != a[4] || row['live_seq'] != a[5]) return 0;
      row['state'] = a[0];
      row['last_seen'] = a[1];
    } else if (sql.startsWith('UPDATE policy_owner SET last_seen=?')) {
      row['last_seen'] = a[0];
    } else {
      throw StateError('Unexpected update');
    }
    return 1;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    if (sql.contains('FROM policy_owner')) {
      return owner == null ? [] : [Map<String, Object?>.of(owner!)];
    }
    if (sql.contains('FROM policy_grant')) {
      final row = grants[arguments![2]];
      return row == null ? [] : [Map<String, Object?>.of(row)];
    }
    throw StateError('Unexpected query');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('WAL mode must actually be active', () {
    validatePolicyWalMode([
      {'journal_mode': 'wal'}
    ]);
    for (final rows in <List<Map<String, Object?>>>[
      [],
      [
        {'journal_mode': 'delete'}
      ],
      [
        {'journal_mode': 'memory'}
      ],
      [
        {'journal_mode': null}
      ],
      [
        {'journal_mode': 'wal', 'extra': 'value'}
      ],
    ]) {
      expect(() => validatePolicyWalMode(rows), throwsStateError);
    }
  });
  test('pending survives coordinator recreation and B cannot revive A',
      () async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final now = DateTime.utc(2026, 11, 6);
    OfflineSessionBinding binding(String sid) => OfflineSessionBinding(
        issuer: 'https://backend.invalid/auth/v1',
        userId: 'a',
        sessionId: sid,
        notBefore: now.subtract(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 1)));
    var current = binding('session-a');
    final db = _Database();
    SqlitePolicyGrantStore makeStore() => SqlitePolicyGrantStore(
        scope: scope,
        currentBinding: () => current,
        coordinator: SqlitePolicyGrantCoordinator(db),
        clock: () => now);
    OfflinePolicyGrant grant() => OfflinePolicyGrant(
        issuer: current.issuer,
        userId: current.userId,
        sessionId: current.sessionId,
        checkedAt: now,
        validUntil: now.add(const Duration(minutes: 30)));
    var store = makeStore();
    final initial = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect(await store.saveAllowed(initial, grant()), isTrue);
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.found);
    final pending = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.blocked);
    store.dispose();
    store = makeStore();
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.blocked);
    session = fakeSession('a', access: 'second-session');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    current = binding('session-b');
    final newer = (await store.beginLiveCheck(scope.capture()!, current))!;
    expect(await store.saveAllowed(newer, grant()), isTrue);
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    current = binding('session-a');
    expect(await store.saveAllowed(pending, grant()), isFalse);
    store.dispose();
    store = makeStore();
    expect((await store.readCandidate(scope.capture()!, current)).status,
        SqliteGrantReadStatus.blocked);
    store.dispose();
    scope.dispose();
    await events.close();
  });
}
