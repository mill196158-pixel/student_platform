import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';

/// Separate from historical ownerless assignment preferences. A caller must
/// obtain a ticket before dispatching a confirmed server request.
class OfflineAssignmentStore {
  OfflineAssignmentStore(this.cache);
  final ProjectChatServerCache cache;
  static const _table = 'offline_team_assignment_v1';
  static final Map<String, int> _pendingDenials = {};
  static final Set<String> _failedDenials = {};
  static bool _denialBlocked(String key) =>
      (_pendingDenials[key] ?? 0) > 0 || _failedDenials.contains(key);
  String _key(OfflineSessionBinding b, String team) =>
      jsonEncode([cache.db.path, cache.project, b.userId, b.sessionId, team]);

  Future<void> _create(DatabaseExecutor txn) => txn.execute(
      'CREATE TABLE IF NOT EXISTS $_table ('
      'project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, '
      'team TEXT NOT NULL, seq INTEGER NOT NULL, denied INTEGER NOT NULL, '
      'payload TEXT, PRIMARY KEY(project,uid,sid,team))');

  bool _same(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a != null && a.issuer == b.issuer && a.userId == b.userId &&
      a.sessionId == b.sessionId && a.notBefore == b.notBefore &&
      a.expiresAt == b.expiresAt;

  bool _valid(AuthOperationScope owner, OfflineSessionBinding binding,
      bool Function() current) {
    try {
      return cache.scope.isCurrent(owner) &&
          _same(cache.currentBinding(), binding) &&
          _same(cache.scope.bindingFor(owner, '${cache.project}/auth/v1'), binding) &&
          current();
    } catch (_) {
      return false;
    }
  }

  List<Object> _args(OfflineSessionBinding b, String team) =>
      [cache.project, b.userId, b.sessionId, team];
  static const _where = 'project=? AND uid=? AND sid=? AND team=?';

  Future<OfflineAssignmentTicket?> begin(String team,
      {required bool Function() isCurrent}) async {
    final owner = cache.scope.capture(), binding = cache.currentBinding();
    if (owner == null || binding == null || team.isEmpty || team.length > 256 ||
        binding.issuer != '${cache.project}/auth/v1' ||
        owner.userId != binding.userId || _denialBlocked(_key(binding, team)) ||
        !_valid(owner, binding, isCurrent)) return null;
    try {
      final seq = await cache.db.transaction((txn) async {
        if (!_valid(owner, binding, isCurrent)) throw const _Stale();
        await _create(txn);
        await txn.insert(_table, {'project': cache.project, 'uid': binding.userId,
          'sid': binding.sessionId, 'team': team, 'seq': 0, 'denied': 0},
          conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.rawUpdate('UPDATE $_table SET seq=seq+1 WHERE $_where', _args(binding, team));
        final rows = await txn.query(_table, columns: ['seq'], where: _where,
            whereArgs: _args(binding, team));
        if (!_valid(owner, binding, isCurrent) || rows.length != 1) throw const _Stale();
        return rows.single['seq'] as int;
      });
      if (!_valid(owner, binding, isCurrent)) return null;
      return OfflineAssignmentTicket._(this, owner, binding, team, seq, isCurrent);
    } catch (_) { return null; }
  }

  bool _current(OfflineAssignmentTicket t) => identical(t.store, this) &&
      !_denialBlocked(_key(t.binding, t.team)) &&
      _valid(t.owner, t.binding, t.current);

  Future<bool> commit(OfflineAssignmentTicket ticket, List<Assignment> values) async {
    if (!_current(ticket) || values.length > 500 ||
        values.any((a) => a.id.isEmpty || a.title.trim().isEmpty)) return false;
    final ids = values.map((a) => a.id).toSet();
    if (ids.length != values.length) return false;
    final payload = jsonEncode(values.map((a) => a.toJson()).toList());
    if (utf8.encode(payload).length > 512 * 1024) return false;
    try {
      return await cache.db.transaction((txn) async {
        if (!_current(ticket)) throw const _Stale();
        final count = await txn.rawUpdate(
            'UPDATE $_table SET payload=?, denied=0 WHERE $_where AND seq=?',
            [payload, ..._args(ticket.binding, ticket.team), ticket.seq]);
        if (count != 1 || !_current(ticket)) throw const _Stale();
        return true;
      });
    } catch (_) { return false; }
  }

  /// A confirmed denial wins over a later request from the same session.
  Future<void> deny(OfflineAssignmentTicket ticket) async {
    if (!_valid(ticket.owner, ticket.binding, () => true)) return;
    final key = _key(ticket.binding, ticket.team);
    _pendingDenials[key] = (_pendingDenials[key] ?? 0) + 1;
    try {
      await cache.db.transaction((txn) async {
        if (!_valid(ticket.owner, ticket.binding, () => true)) throw const _Stale();
        await txn.rawUpdate('UPDATE $_table SET seq=seq+1, denied=1 WHERE $_where',
            _args(ticket.binding, ticket.team));
        if (!_valid(ticket.owner, ticket.binding, () => true)) throw const _Stale();
      });
    } catch (_) {
      _failedDenials.add(key);
    } finally {
      final remaining = (_pendingDenials[key] ?? 1) - 1;
      if (remaining == 0) {
        _pendingDenials.remove(key);
      } else {
        _pendingDenials[key] = remaining;
      }
    }
  }

  Future<List<Assignment>?> read(String team, SessionCapabilities caps) async {
    final owner = cache.scope.capture(), binding = cache.currentBinding();
    final permit = caps.capture(SessionCapability.cachedRead);
    if (owner == null || binding == null || permit == null || team.isEmpty ||
        caps.mode != SessionCapabilityMode.cacheOnly || !caps.owns(permit, owner)) return null;
    bool current() => _valid(owner, binding, () =>
        caps.mode == SessionCapabilityMode.cacheOnly &&
        !_denialBlocked(_key(binding, team)) &&
        caps.permits(permit, SessionCapability.cachedRead));
    if (!current()) return null;
    try {
      return await cache.db.transaction((txn) async {
        if (!current()) return null;
        await _create(txn);
        final rows = await txn.rawQuery(
            'SELECT payload,denied FROM $_table WHERE $_where '
            'AND length(CAST(payload AS BLOB))<=?', [..._args(binding, team), 512 * 1024]);
        if (!current() || rows.length != 1 || rows.single['denied'] != 0 ||
            rows.single['payload'] is! String) return null;
        final value = jsonDecode(rows.single['payload'] as String);
        if (value is! List || value.length > 500) return null;
        final result = <Assignment>[];
        final ids = <String>{};
        for (final row in value) {
          if (row is! Map || row['id'] is! String || row['title'] is! String ||
              (row['id'] as String).isEmpty || (row['title'] as String).trim().isEmpty ||
              !ids.add(row['id'] as String)) return null;
          result.add(Assignment.fromJson(Map<String, dynamic>.from(row)));
        }
        return current() ? result : null;
      });
    } catch (_) { return null; }
  }
}

class OfflineAssignmentTicket {
  OfflineAssignmentTicket._(this.store, this.owner, this.binding, this.team, this.seq, this.current);
  final OfflineAssignmentStore store;
  final AuthOperationScope owner;
  final OfflineSessionBinding binding;
  final String team;
  final int seq;
  final bool Function() current;
}

class _Stale implements Exception { const _Stale(); }
