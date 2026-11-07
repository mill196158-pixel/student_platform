import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

/// A verified online subject plan, scoped to the actual project and session.
/// Historical UID-only preferences are intentionally never read here.
class OfflineSubjectCatalog {
  OfflineSubjectCatalog(this.cache);
  final ProjectChatServerCache cache;
  static const _table = 'offline_subject_catalog_v1';
  static const _where = 'project=? AND uid=? AND sid=?';
  static final Map<String, int> _pendingDenials = {};
  static final Set<String> _failedDenials = {};
  static bool _blocked(String key) => (_pendingDenials[key] ?? 0) > 0 || _failedDenials.contains(key);
  String _key(OfflineSessionBinding b) => jsonEncode([cache.db.path, cache.project, b.userId, b.sessionId]);
  List<Object> _args(OfflineSessionBinding b) => [cache.project, b.userId, b.sessionId];

  Future<void> _create(DatabaseExecutor db) => db.execute(
      'CREATE TABLE IF NOT EXISTS $_table (project TEXT NOT NULL, uid TEXT NOT NULL, '
      'sid TEXT NOT NULL, seq INTEGER NOT NULL, denied INTEGER NOT NULL, payload TEXT, '
      'PRIMARY KEY(project,uid,sid))');
  bool _same(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a != null && a.issuer == b.issuer && a.userId == b.userId &&
      a.sessionId == b.sessionId && a.notBefore == b.notBefore && a.expiresAt == b.expiresAt;
  bool _valid(AuthOperationScope owner, OfflineSessionBinding binding, bool Function() guard) {
    try {
      return cache.scope.isCurrent(owner) && _same(cache.currentBinding(), binding) &&
          _same(cache.scope.bindingFor(owner, '${cache.project}/auth/v1'), binding) && guard();
    } catch (_) { return false; }
  }

  Future<SubjectCatalogTicket?> begin({required bool Function() isCurrent}) async {
    final owner = cache.scope.capture(), binding = cache.currentBinding();
    if (owner == null || binding == null || owner.userId != binding.userId ||
        binding.issuer != '${cache.project}/auth/v1' || _blocked(_key(binding)) ||
        !_valid(owner, binding, isCurrent)) return null;
    try {
      final seq = await cache.db.transaction((txn) async {
        if (!_valid(owner, binding, isCurrent)) throw const _Stale();
        await _create(txn);
        await txn.insert(_table, {'project': cache.project, 'uid': binding.userId,
          'sid': binding.sessionId, 'seq': 0, 'denied': 0}, conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.rawUpdate('UPDATE $_table SET seq=seq+1 WHERE $_where', _args(binding));
        final rows = await txn.query(_table, columns: ['seq'], where: _where, whereArgs: _args(binding));
        if (!_valid(owner, binding, isCurrent) || rows.length != 1) throw const _Stale();
        return rows.single['seq'] as int;
      });
      if (!_valid(owner, binding, isCurrent)) return null;
      return SubjectCatalogTicket._(this, owner, binding, seq, isCurrent);
    } catch (_) { return null; }
  }

  bool _current(SubjectCatalogTicket t) => identical(t.store, this) &&
      !_blocked(_key(t.binding)) && _valid(t.owner, t.binding, t.current);

  static bool _wellFormed(Map<String, dynamic> value, String uid) {
    final context = value['contextData'], subjects = value['subjects'];
    if (context is! Map || context['userId'] != uid ||
        context['groupId'] is! String || (context['groupId'] as String).isEmpty ||
        subjects is! List || subjects.length > 1000 || value['warning'] != null) return false;
    final ids = <String>{};
    for (final row in subjects) {
      if (row is! Map || row['id'] is! String || (row['id'] as String).isEmpty ||
          !ids.add(row['id'] as String) || row['title'] is! String ||
          (row['title'] as String).trim().isEmpty || row['controlForm'] is! String ||
          (row['semesterNumber'] != null && row['semesterNumber'] is! int) ||
          (row['groupId'] != null && row['groupId'] != context['groupId'])) return false;
    }
    return true;
  }

  Future<bool> commit(SubjectCatalogTicket ticket, Map<String, dynamic> value) async {
    if (!_current(ticket) || !_wellFormed(value, ticket.owner.userId)) return false;
    final payload = jsonEncode(value);
    if (utf8.encode(payload).length > 512 * 1024) return false;
    try {
      return await cache.db.transaction((txn) async {
        if (!_current(ticket)) throw const _Stale();
        final n = await txn.rawUpdate('UPDATE $_table SET payload=?,denied=0 WHERE $_where AND seq=?',
            [payload, ..._args(ticket.binding), ticket.seq]);
        if (n != 1 || !_current(ticket)) throw const _Stale();
        return true;
      });
    } catch (_) { return false; }
  }

  Future<void> deny(SubjectCatalogTicket ticket) async {
    if (!_valid(ticket.owner, ticket.binding, () => true)) return;
    final key = _key(ticket.binding);
    _pendingDenials[key] = (_pendingDenials[key] ?? 0) + 1;
    try {
      await cache.db.transaction((txn) async {
        if (!_valid(ticket.owner, ticket.binding, () => true)) throw const _Stale();
        await txn.rawUpdate('UPDATE $_table SET seq=seq+1,denied=1 WHERE $_where', _args(ticket.binding));
        if (!_valid(ticket.owner, ticket.binding, () => true)) throw const _Stale();
      });
    } catch (_) { _failedDenials.add(key); }
    finally {
      final remaining = (_pendingDenials[key] ?? 1) - 1;
      if (remaining == 0) { _pendingDenials.remove(key); }
      else { _pendingDenials[key] = remaining; }
    }
  }

  Future<Map<String, dynamic>?> read(SessionCapabilities caps) async {
    final owner = cache.scope.capture(), binding = cache.currentBinding();
    final permit = caps.capture(SessionCapability.cachedRead);
    if (owner == null || binding == null || permit == null ||
        caps.mode != SessionCapabilityMode.cacheOnly || !caps.owns(permit, owner)) return null;
    bool current() => !_blocked(_key(binding)) && _valid(owner, binding,
      () => caps.mode == SessionCapabilityMode.cacheOnly && caps.permits(permit, SessionCapability.cachedRead));
    if (!current()) return null;
    try {
      return await cache.db.transaction((txn) async {
        if (!current()) return null;
        await _create(txn);
        final rows = await txn.rawQuery('SELECT payload,denied FROM $_table WHERE $_where '
            'AND length(CAST(payload AS BLOB))<=?', [..._args(binding), 512 * 1024]);
        if (!current() || rows.length != 1 || rows.single['denied'] != 0 || rows.single['payload'] is! String) return null;
        final decoded = jsonDecode(rows.single['payload'] as String);
        if (decoded is! Map) return null;
        final value = Map<String, dynamic>.from(decoded);
        return current() && _wellFormed(value, owner.userId) ? value : null;
      });
    } catch (_) { return null; }
  }
}

class SubjectCatalogTicket {
  SubjectCatalogTicket._(this.store, this.owner, this.binding, this.seq, this.current);
  final OfflineSubjectCatalog store;
  final AuthOperationScope owner;
  final OfflineSessionBinding binding;
  final int seq;
  final bool Function() current;
}
class _Stale implements Exception { const _Stale(); }
