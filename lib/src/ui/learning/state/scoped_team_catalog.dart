import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';

class TeamCatalogTicket {
  TeamCatalogTicket._(this.issuer, this.owner, this.binding, this.permit,
      this.sequence, this.sourceCurrent);
  final Object issuer;
  final AuthOperationScope owner;
  final OfflineSessionBinding binding;
  final CapabilityPermit permit;
  final int sequence;
  final bool Function() sourceCurrent;
}

class TeamCatalogSnapshot {
  const TeamCatalogSnapshot(this.teams, this.savedAt);
  final List<Team> teams;
  final DateTime savedAt;
}

class _StaleCatalog implements Exception {
  const _StaleCatalog();
}

/// Local catalogue only; callers must provide a confirmed complete server page.
/// Legacy ownerless preferences and message bodies are never read here.
class ScopedTeamCatalogStore {
  ScopedTeamCatalogStore(
      {required this.db,
      required this.scope,
      required this.currentBinding,
      required this.project});
  final Database db;
  final AuthSessionScope scope;
  final OfflineSessionBinding? Function() currentBinding;
  final String project;
  final Object _issuer = Object();
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static final Map<String, int> _pendingDenials = {};
  static final Set<String> _failedDenials = {};
  @visibleForTesting
  Future<void> Function()? debugBeforeDenialCommit;
  String _ownerKey(OfflineSessionBinding binding) =>
      jsonEncode([db.path, project, binding.userId, binding.sessionId]);
  bool _quarantined(OfflineSessionBinding binding) =>
      (_pendingDenials[_ownerKey(binding)] ?? 0) > 0 ||
      _failedDenials.contains(_ownerKey(binding));

  Future<void> initialize() async {
    await db.execute('CREATE TABLE IF NOT EXISTS scoped_team_catalog ('
        'project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, '
        'seq INTEGER NOT NULL, saved_at INTEGER, payload TEXT, '
        'denied INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(project,uid,sid))');
    var columns = await db.rawQuery('PRAGMA table_info(scoped_team_catalog)');
    if (!columns.any((row) => row['name'] == 'denied')) {
      try {
        await db.execute(
            'ALTER TABLE scoped_team_catalog ADD COLUMN denied INTEGER NOT NULL DEFAULT 0');
      } catch (_) {
        // Another engine may have completed the same additive migration.
        columns = await db.rawQuery('PRAGMA table_info(scoped_team_catalog)');
        if (!columns.any((row) => row['name'] == 'denied')) rethrow;
      }
    }
  }

  bool _same(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a != null &&
      a.issuer == b.issuer &&
      a.userId == b.userId &&
      a.sessionId == b.sessionId;
  bool _valid(
      AuthOperationScope owner,
      OfflineSessionBinding binding,
      SessionCapabilities caps,
      CapabilityPermit permit,
      SessionCapability capability) {
    try {
      return binding.issuer == '$project/auth/v1' &&
          owner.userId == binding.userId &&
          scope.isCurrent(owner) &&
          _same(scope.bindingFor(owner, binding.issuer), binding) &&
          _same(currentBinding(), binding) &&
          caps.ownsFor(permit, owner, capability);
    } catch (_) {
      return false;
    }
  }

  List<Object> _args(OfflineSessionBinding binding) =>
      [project, binding.userId, binding.sessionId];
  static const _where = 'project=? AND uid=? AND sid=?';

  Future<TeamCatalogTicket?> begin(SessionCapabilities caps,
      {bool Function()? sourceCurrent}) async {
    bool sourceValid() {
      try {
        return sourceCurrent?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    final owner = scope.capture(), binding = currentBinding();
    final permit = caps.capture(SessionCapability.networkRead);
    if (owner == null ||
        binding == null ||
        permit == null ||
        !_valid(owner, binding, caps, permit, SessionCapability.networkRead) ||
        !sourceValid()) return null;
    try {
      await initialize();
      return await db.transaction((txn) async {
        if (!sourceValid() ||
            !_valid(
                owner, binding, caps, permit, SessionCapability.networkRead))
          throw const _StaleCatalog();
        await txn.insert(
            'scoped_team_catalog',
            {
              'project': project,
              'uid': binding.userId,
              'sid': binding.sessionId,
              'seq': 0
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await txn.rawUpdate(
            'UPDATE scoped_team_catalog SET seq=seq+1 WHERE $_where',
            _args(binding));
        final rows = await txn.query('scoped_team_catalog',
            columns: ['seq'], where: _where, whereArgs: _args(binding));
        if (rows.length != 1 ||
            !sourceValid() ||
            !_valid(
                owner, binding, caps, permit, SessionCapability.networkRead))
          throw const _StaleCatalog();
        return TeamCatalogTicket._(_issuer, owner, binding, permit,
            rows.single['seq'] as int, sourceValid);
      });
    } catch (_) {
      return null;
    }
  }

  Future<bool> commit(TeamCatalogTicket ticket, SessionCapabilities caps,
      List<Team> teams, DateTime savedAt) async {
    if (!identical(ticket.issuer, _issuer) ||
        _quarantined(ticket.binding) ||
        !ticket.sourceCurrent() ||
        teams.length > 500 ||
        teams.map((t) => t.id).toSet().length != teams.length ||
        teams.any((t) =>
            t.id.isEmpty ||
            t.id.length > 256 ||
            t.name.length > 512 ||
            t.teacher.length > 512 ||
            t.groupCode.length > 256 ||
            t.icon.length > 128 ||
            !const {'subject', 'group_space', 'unknown'}.contains(t.kind)))
      return false;
    final payload = jsonEncode(teams.map((t) => t.toJson()).toList());
    if (utf8.encode(payload).length > 512 * 1024) return false;
    try {
      final saved = await db.transaction((txn) async {
        if (_quarantined(ticket.binding) ||
            !ticket.sourceCurrent() ||
            !_valid(ticket.owner, ticket.binding, caps, ticket.permit,
                SessionCapability.networkRead)) throw const _StaleCatalog();
        final updated = await txn.update(
            'scoped_team_catalog',
            {
              'payload': payload,
              'saved_at': savedAt.toUtc().millisecondsSinceEpoch,
              'denied': 0
            },
            where: '$_where AND seq=?',
            whereArgs: [..._args(ticket.binding), ticket.sequence]);
        if (updated != 1 ||
            _quarantined(ticket.binding) ||
            !ticket.sourceCurrent() ||
            !_valid(ticket.owner, ticket.binding, caps, ticket.permit,
                SessionCapability.networkRead)) throw const _StaleCatalog();
        return true;
      });
      if (saved) changes.value++;
      return saved;
    } catch (_) {
      return false;
    }
  }

  /// Confirmed server denial invalidates any in-flight attempt for this same
  /// session. Preserve the bytes for rollback; never alter another owner.
  Future<bool> deny(TeamCatalogTicket ticket) async {
    bool sameSession() {
      try {
        return identical(ticket.issuer, _issuer) &&
            scope.isCurrent(ticket.owner) &&
            _same(scope.bindingFor(ticket.owner, ticket.binding.issuer),
                ticket.binding) &&
            _same(currentBinding(), ticket.binding);
      } catch (_) {
        return false;
      }
    }

    if (!sameSession()) return false;
    final key = _ownerKey(ticket.binding);
    _pendingDenials[key] = (_pendingDenials[key] ?? 0) + 1;
    changes.value++;
    var persisted = false;
    try {
      await debugBeforeDenialCommit?.call();
      await initialize();
      persisted = await db.transaction((txn) async {
        if (!sameSession()) throw const _StaleCatalog();
        final count = await txn.rawUpdate(
            'UPDATE scoped_team_catalog SET seq=seq+1, denied=1 WHERE $_where',
            _args(ticket.binding));
        if (count != 1 || !sameSession()) throw const _StaleCatalog();
        return true;
      });
      return persisted;
    } catch (_) {
      return false;
    } finally {
      if (!persisted) _failedDenials.add(key);
      final left = (_pendingDenials[key] ?? 1) - 1;
      if (left <= 0) {
        _pendingDenials.remove(key);
      } else {
        _pendingDenials[key] = left;
      }
      changes.value++;
    }
  }

  /// True means fail closed, false means there is no denied marker, null means
  /// storage could not be checked. It never reveals another session's state.
  Future<bool?> isDenied(SessionCapabilities caps) async {
    final owner = scope.capture(), binding = currentBinding();
    final permit = caps.capture(SessionCapability.cachedRead);
    if (owner == null ||
        binding == null ||
        permit == null ||
        caps.mode != SessionCapabilityMode.cacheOnly ||
        !_valid(owner, binding, caps, permit, SessionCapability.cachedRead))
      return null;
    if (_quarantined(binding)) return true;
    try {
      await initialize();
      return await db.transaction((txn) async {
        if (!_valid(owner, binding, caps, permit, SessionCapability.cachedRead))
          return null;
        final rows = await txn.query('scoped_team_catalog',
            columns: ['denied'], where: _where, whereArgs: _args(binding));
        if (!_valid(owner, binding, caps, permit, SessionCapability.cachedRead))
          return null;
        if (_quarantined(binding)) return true;
        if (rows.isEmpty) return false;
        if (rows.length != 1 ||
            (rows.single['denied'] != 0 && rows.single['denied'] != 1))
          return null;
        return rows.single['denied'] == 1;
      });
    } catch (_) {
      return null;
    }
  }

  Future<TeamCatalogSnapshot?> read(SessionCapabilities caps) async {
    final owner = scope.capture(), binding = currentBinding();
    final permit = caps.capture(SessionCapability.cachedRead);
    if (owner == null ||
        binding == null ||
        permit == null ||
        _quarantined(binding) ||
        caps.mode != SessionCapabilityMode.cacheOnly ||
        !_valid(owner, binding, caps, permit, SessionCapability.cachedRead))
      return null;
    try {
      await initialize();
      return await db.transaction((txn) async {
        if (!_valid(owner, binding, caps, permit, SessionCapability.cachedRead))
          return null;
        final rows = await txn.query('scoped_team_catalog',
            columns: ['payload', 'saved_at', 'denied'],
            where: _where,
            whereArgs: _args(binding));
        if (rows.length != 1 ||
            rows.single['payload'] is! String ||
            rows.single['saved_at'] is! int ||
            rows.single['denied'] != 0) return null;
        final raw = rows.single['payload'] as String;
        if (utf8.encode(raw).length > 512 * 1024) return null;
        final decoded = jsonDecode(raw);
        if (decoded is! List || decoded.length > 500) return null;
        final teams = <Team>[];
        for (final row in decoded) {
          if (row is! Map ||
              row['id'] is! String ||
              (row['id'] as String).isEmpty ||
              row['name'] is! String ||
              row['teacher'] is! String ||
              row['groupCode'] is! String ||
              row['icon'] is! String ||
              !const {'subject', 'group_space', 'unknown'}
                  .contains(row['kind'])) return null;
          teams.add(Team.fromJson(Map<String, dynamic>.from(row)));
        }
        if (teams.map((t) => t.id).toSet().length != teams.length ||
            _quarantined(binding) ||
            !_valid(owner, binding, caps, permit, SessionCapability.cachedRead))
          return null;
        return TeamCatalogSnapshot(
            List.unmodifiable(teams),
            DateTime.fromMillisecondsSinceEpoch(rows.single['saved_at'] as int,
                isUtc: true));
      });
    } catch (_) {
      return null;
    }
  }
}
