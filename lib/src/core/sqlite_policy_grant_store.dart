import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'auth_session_scope.dart';
import 'offline_policy_grant.dart';

/// Opens a separate local security database. Never imports legacy preference
/// grants, and never recreates an unknown newer schema.
Future<Database> openPolicyGrantDatabase(String path,
    {DatabaseFactory? factory}) async {
  final dbFactory = factory ?? databaseFactory;
  return dbFactory.openDatabase(path,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) async {
          validatePolicyWalMode(await db.rawQuery('PRAGMA journal_mode=WAL'));
          await db.execute('PRAGMA synchronous=FULL');
        },
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE policy_owner ('
              'issuer TEXT NOT NULL, uid TEXT NOT NULL, epoch INTEGER NOT NULL CHECK(epoch>=0), '
              'live_seq INTEGER NOT NULL CHECK(live_seq>=0), state TEXT NOT NULL CHECK(state IN (\'active\',\'revoked\')), last_seen TEXT, '
              'PRIMARY KEY (issuer, uid))');
          await db.execute('CREATE TABLE policy_grant ('
              'issuer TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, '
              'owner_epoch INTEGER NOT NULL CHECK(owner_epoch>=0), live_seq INTEGER NOT NULL CHECK(live_seq>0), '
              'checked_at TEXT NOT NULL, valid_until TEXT NOT NULL, '
              'token_nbf TEXT, token_exp TEXT, '
              'PRIMARY KEY (issuer, uid, sid))');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion != 1 || newVersion != 2) {
            throw StateError('Unknown policy database migration');
          }
          await _validatePolicySchema(db, legacyV1: true);
          // Old records lack evidence of the original token window and are
          // kept but fail closed until a new verified online policy check.
          await db
              .execute('ALTER TABLE policy_grant ADD COLUMN token_nbf TEXT');
          await db
              .execute('ALTER TABLE policy_grant ADD COLUMN token_exp TEXT');
        },
        onDowngrade: (_, __, ___) =>
            throw StateError('Unknown policy database version'),
        onOpen: (db) => _validatePolicySchema(db),
      ));
}

@visibleForTesting
void validatePolicyWalMode(List<Map<String, Object?>> rows) {
  if (rows.length != 1 ||
      rows.single.length != 1 ||
      rows.single.values.single is! String ||
      (rows.single.values.single as String).toLowerCase() != 'wal') {
    throw StateError('Policy database WAL unavailable');
  }
}

Future<void> _validatePolicySchema(Database db, {bool legacyV1 = false}) async {
  validatePolicyWalMode(await db.rawQuery('PRAGMA journal_mode'));
  const expected = <String, List<(String, String, int, int)>>{
    'policy_owner': [
      ('issuer', 'TEXT', 1, 1),
      ('uid', 'TEXT', 1, 2),
      ('epoch', 'INTEGER', 1, 0),
      ('live_seq', 'INTEGER', 1, 0),
      ('state', 'TEXT', 1, 0),
      ('last_seen', 'TEXT', 0, 0),
    ],
    'policy_grant': [
      ('issuer', 'TEXT', 1, 1),
      ('uid', 'TEXT', 1, 2),
      ('sid', 'TEXT', 1, 3),
      ('owner_epoch', 'INTEGER', 1, 0),
      ('live_seq', 'INTEGER', 1, 0),
      ('checked_at', 'TEXT', 1, 0),
      ('valid_until', 'TEXT', 1, 0),
      ('token_nbf', 'TEXT', 0, 0),
      ('token_exp', 'TEXT', 0, 0),
    ],
  };
  for (final entry in expected.entries) {
    final rows = await db.rawQuery('PRAGMA table_info(${entry.key})');
    final columns = legacyV1 && entry.key == 'policy_grant'
        ? entry.value.take(7).toList()
        : entry.value;
    if (rows.length != columns.length)
      throw StateError('Invalid policy database schema');
    for (var i = 0; i < rows.length; i++) {
      final expectedColumn = columns[i], row = rows[i];
      if (row['name'] != expectedColumn.$1 ||
          row['type'] != expectedColumn.$2 ||
          row['notnull'] != expectedColumn.$3 ||
          row['pk'] != expectedColumn.$4) {
        throw StateError('Invalid policy database schema');
      }
    }
    final schema = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
        [entry.key]);
    if (schema.length != 1 || schema.single['sql'] is! String) {
      throw StateError('Invalid policy database schema');
    }
    final sql = (schema.single['sql'] as String)
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '');
    final checks = entry.key == 'policy_owner'
        ? [
            "check(epoch>=0)",
            "check(live_seq>=0)",
            "check(statein('active','revoked'))"
          ]
        : ['check(owner_epoch>=0)', 'check(live_seq>0)'];
    if (checks.any((check) => !sql.contains(check)))
      throw StateError('Invalid policy database schema');
  }
  final synchronous = await db.rawQuery('PRAGMA synchronous');
  if (synchronous.length != 1 || synchronous.single.values.single != 2) {
    throw StateError('Policy database durability unavailable');
  }
}

enum SqliteGrantReadStatus { found, blocked, unavailable }

class SqliteGrantReadResult {
  const SqliteGrantReadResult(this.status, [this.grant]);
  final SqliteGrantReadStatus status;
  final OfflinePolicyGrant? grant;
}

class SqliteRevokeReceipt {
  const SqliteRevokeReceipt._(this.epoch);
  final int epoch;
}

class SqliteLiveGrantAttempt {
  SqliteLiveGrantAttempt._(this._issuer, this._owner, this._binding,
      this._memoryRevision, this._durableEpoch, this._liveSequence);
  final Object _issuer;
  final AuthOperationScope _owner;
  final OfflineSessionBinding _binding;
  final int _memoryRevision;
  final int _durableEpoch;
  final int _liveSequence;
  bool _used = false;
}

/// Captured before any refresh dispatch; retains no credentials. This is
/// evidence of the prior durable row, never an offline permit by itself.
class SqlitePriorGrantReceipt {
  SqlitePriorGrantReceipt._(
      this._issuer,
      this._owner,
      this._binding,
      this._epoch,
      this._sequence,
      this._checkedAt,
      this._validUntil,
      this._tokenNbf,
      this._tokenExp);
  final Object _issuer;
  final AuthOperationScope _owner;
  final OfflineSessionBinding _binding;
  final int _epoch, _sequence;
  final Object? _checkedAt, _validUntil, _tokenNbf, _tokenExp;
  bool _used = false;
}

/// Shared for all instances using the same database. No network is performed
/// while a transaction is open. This class does not grant app capabilities.
class SqlitePolicyGrantCoordinator {
  SqlitePolicyGrantCoordinator(this.db);
  final Database db;
  final _revision = <String, int>{};
  final _blocked = <String>{};
  final _cleanup = <String>{};
  final _quarantined = <String>{};
  bool isBlocked(String key) =>
      _blocked.contains(key) ||
      _cleanup.contains(key) ||
      _quarantined.contains(key);
  final _queues = <String, Future<void>>{};
  static String key(String issuer, String uid) => jsonEncode([issuer, uid]);
  Future<T> serial<T>(String key, Future<T> Function() work) {
    final result = Completer<T>();
    final previous = _queues[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) async {
      try {
        result.complete(await work());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).whenComplete(() {
      if (identical(_queues[key], next)) _queues.remove(key);
    });
    _queues[key] = next;
    return result.future;
  }
}

class _PolicyStale implements Exception {
  const _PolicyStale();
}

class SqlitePolicyGrantStore {
  SqlitePolicyGrantStore(
      {required this.scope,
      required this.currentBinding,
      required this.coordinator,
      DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final AuthSessionScope scope;
  final OfflineSessionBinding? Function() currentBinding;
  final SqlitePolicyGrantCoordinator coordinator;
  final DateTime Function() _clock;
  final Object _issuer = Object();
  bool _disposed = false;

  String _key(OfflineSessionBinding b) =>
      SqlitePolicyGrantCoordinator.key(b.issuer, b.userId);
  bool _same(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a != null &&
      a.issuer == b.issuer &&
      a.userId == b.userId &&
      a.sessionId == b.sessionId &&
      a.notBefore.isAtSameMomentAs(b.notBefore) &&
      a.expiresAt.isAtSameMomentAs(b.expiresAt);
  bool _current(
          AuthOperationScope owner, OfflineSessionBinding b, int revision) =>
      !_disposed &&
      scope.isCurrent(owner) &&
      owner.userId == b.userId &&
      _same(currentBinding(), b) &&
      !coordinator.isBlocked(_key(b)) &&
      (coordinator._revision[_key(b)] ?? 0) == revision;

  /// Must complete before the live policy RPC starts.
  Future<SqliteLiveGrantAttempt?> beginLiveCheck(
      AuthOperationScope owner, OfflineSessionBinding binding) {
    final key = _key(binding);
    if (_disposed ||
        !scope.isCurrent(owner) ||
        owner.userId != binding.userId ||
        !_same(currentBinding(), binding) ||
        coordinator.isBlocked(key)) return Future.value(null);
    final revision = (coordinator._revision[key] ?? 0) + 1;
    coordinator._revision[key] = revision;
    return coordinator.serial(key, () async {
      if (!_current(owner, binding, revision)) return null;
      try {
        final pair = await coordinator.db.transaction((txn) async {
          if (!_current(owner, binding, revision)) throw const _PolicyStale();
          await txn.rawInsert(
              'INSERT OR IGNORE INTO policy_owner '
              '(issuer,uid,epoch,live_seq,state,last_seen) VALUES (?,?,0,0,?,NULL)',
              [binding.issuer, binding.userId, 'revoked']);
          await txn.rawUpdate(
              "UPDATE policy_owner SET live_seq=live_seq+1,state='revoked' WHERE issuer=? AND uid=?",
              [binding.issuer, binding.userId]);
          final rows = await txn.rawQuery(
              'SELECT epoch,live_seq FROM policy_owner WHERE issuer=? AND uid=?',
              [binding.issuer, binding.userId]);
          if (!_current(owner, binding, revision) ||
              rows.length != 1 ||
              rows.single['epoch'] is! int ||
              (rows.single['epoch'] as int) < 0 ||
              rows.single['live_seq'] is! int ||
              (rows.single['live_seq'] as int) <= 0) throw const _PolicyStale();
          return (rows.single['epoch'] as int, rows.single['live_seq'] as int);
        });
        if (!_current(owner, binding, revision)) return null;
        return SqliteLiveGrantAttempt._(
            _issuer, owner, binding, revision, pair.$1, pair.$2);
      } on _PolicyStale {
        return null;
      }
    });
  }

  /// The caller must separately verify that a live policy result allows access.
  Future<bool> saveAllowed(
      SqliteLiveGrantAttempt attempt, OfflinePolicyGrant grant,
      {bool Function()? stillCurrent}) {
    if (!identical(attempt._issuer, _issuer) || attempt._used)
      return Future.value(false);
    attempt._used = true;
    final b = attempt._binding;
    if (OfflinePolicyGrant.fromJson(grant.toJson(),
                maximumAge: OfflinePolicyGrant.maximumLocalSnapshotLifetime) ==
            null ||
        !grant.matchesForLocalSnapshot(b, now: grant.checkedAt) ||
        grant.checkedAt.isAfter(_clock().toUtc())) return Future.value(false);
    bool current() {
      try {
        return _current(attempt._owner, b, attempt._memoryRevision) &&
            (stillCurrent?.call() ?? true);
      } catch (_) {
        return false;
      }
    }

    return coordinator.serial(_key(b), () async {
      if (!current()) return false;
      try {
        final saved = await coordinator.db.transaction((txn) async {
          if (!current()) throw const _PolicyStale();
          final rows = await txn.rawQuery(
              'SELECT epoch,live_seq,last_seen FROM policy_owner WHERE issuer=? AND uid=?',
              [b.issuer, b.userId]);
          if (rows.length != 1 ||
              rows.single['epoch'] != attempt._durableEpoch ||
              rows.single['live_seq'] != attempt._liveSequence) return false;
          final seen = rows.single['last_seen'];
          if (seen != null) {
            if (seen is! String) return false;
            final date = DateTime.tryParse(seen);
            if (date == null ||
                !date.isUtc ||
                date.toIso8601String() != seen ||
                grant.checkedAt.isBefore(date)) return false;
          }
          await txn.rawInsert(
              'INSERT OR REPLACE INTO policy_grant '
              '(issuer,uid,sid,owner_epoch,live_seq,checked_at,valid_until,token_nbf,token_exp) VALUES (?,?,?,?,?,?,?,?,?)',
              [
                b.issuer,
                b.userId,
                b.sessionId,
                attempt._durableEpoch,
                attempt._liveSequence,
                grant.checkedAt.toUtc().toIso8601String(),
                grant.validUntil.toUtc().toIso8601String(),
                b.notBefore.toUtc().toIso8601String(),
                b.expiresAt.toUtc().toIso8601String()
              ]);
          await txn.rawUpdate(
              'UPDATE policy_owner SET state=?,last_seen=? WHERE issuer=? AND uid=? AND epoch=? AND live_seq=?',
              [
                'active',
                grant.checkedAt.toUtc().toIso8601String(),
                b.issuer,
                b.userId,
                attempt._durableEpoch,
                attempt._liveSequence
              ]);
          if (!current()) throw const _PolicyStale();
          return true;
        });
        if (!saved) return false;
        if (!current()) {
          final key = _key(b);
          coordinator._cleanup.add(key);
          // Never remove a newer grant when cleanup follows a stale commit.
          try {
            await coordinator.db.transaction((txn) async {
              await txn.rawDelete(
                  'DELETE FROM policy_grant WHERE issuer=? AND uid=? AND sid=? AND owner_epoch=? AND live_seq=?',
                  [
                    b.issuer,
                    b.userId,
                    b.sessionId,
                    attempt._durableEpoch,
                    attempt._liveSequence
                  ]);
              await txn.rawUpdate(
                  'UPDATE policy_owner SET state=? WHERE issuer=? AND uid=? AND epoch=? AND live_seq=?',
                  [
                    'revoked',
                    b.issuer,
                    b.userId,
                    attempt._durableEpoch,
                    attempt._liveSequence
                  ]);
            });
          } catch (_) {
            coordinator._quarantined.add(key);
            rethrow;
          } finally {
            coordinator._cleanup.remove(key);
          }
          return false;
        }
        return true;
      } on _PolicyStale {
        return false;
      }
    });
  }

  /// A confirmed denial may revoke only the exact still-current live attempt.
  /// The memory fence is installed synchronously before the database awaits.
  Future<bool> revokeAfterLiveCheck(SqliteLiveGrantAttempt attempt) {
    if (!identical(attempt._issuer, _issuer) || attempt._used) {
      return Future.value(false);
    }
    final binding = attempt._binding;
    final key = _key(binding);
    if (!_current(attempt._owner, binding, attempt._memoryRevision)) {
      return Future.value(false);
    }
    attempt._used = true;
    coordinator._blocked.add(key);
    bool valid() =>
        !_disposed &&
        scope.isCurrent(attempt._owner) &&
        _same(currentBinding(), binding) &&
        !coordinator._cleanup.contains(key) &&
        !coordinator._quarantined.contains(key) &&
        (coordinator._revision[key] ?? 0) == attempt._memoryRevision;
    return coordinator.serial(key, () async {
      try {
        if (!valid()) return false;
        return await coordinator.db.transaction((txn) async {
          if (!valid()) throw const _PolicyStale();
          final rows = await txn.rawQuery(
              'SELECT epoch,live_seq FROM policy_owner WHERE issuer=? AND uid=?',
              [binding.issuer, binding.userId]);
          if (rows.length != 1 ||
              rows.single['epoch'] != attempt._durableEpoch ||
              rows.single['live_seq'] != attempt._liveSequence) return false;
          await txn.rawUpdate(
              'UPDATE policy_owner SET epoch=epoch+1,live_seq=live_seq+1,state=? WHERE issuer=? AND uid=?',
              ['revoked', binding.issuer, binding.userId]);
          await txn.rawDelete(
              'DELETE FROM policy_grant WHERE issuer=? AND uid=?',
              [binding.issuer, binding.userId]);
          if (!valid()) throw const _PolicyStale();
          return true;
        });
      } on _PolicyStale {
        return false;
      } catch (_) {
        coordinator._quarantined.add(key);
        rethrow;
      } finally {
        if ((coordinator._revision[key] ?? 0) == attempt._memoryRevision &&
            !coordinator._quarantined.contains(key)) {
          coordinator._blocked.remove(key);
        }
      }
    });
  }

  /// Memory fence is synchronous; only the returned receipt proves a commit.
  Future<SqliteRevokeReceipt> beginRevoke(OfflineSessionBinding binding,
      {bool Function()? stillCurrent}) {
    bool valid() => stillCurrent?.call() ?? true;
    if (!valid()) return Future.error(const _PolicyStale());
    final key = _key(binding);
    if (_disposed) return Future.error(StateError('Store disposed'));
    final revision = (coordinator._revision[key] ?? 0) + 1;
    coordinator._revision[key] = revision;
    coordinator._blocked.add(key);
    return coordinator.serial(key, () async {
      final epoch = await coordinator.db.transaction((txn) async {
        if (!valid()) throw const _PolicyStale();
        await txn.rawInsert(
            'INSERT OR IGNORE INTO policy_owner '
            '(issuer,uid,epoch,live_seq,state,last_seen) VALUES (?,?,0,0,?,NULL)',
            [binding.issuer, binding.userId, 'revoked']);
        if (!valid()) throw const _PolicyStale();
        await txn.rawUpdate(
            'UPDATE policy_owner SET epoch=epoch+1,live_seq=live_seq+1,state=? WHERE issuer=? AND uid=?',
            ['revoked', binding.issuer, binding.userId]);
        if (!valid()) throw const _PolicyStale();
        await txn.rawDelete('DELETE FROM policy_grant WHERE issuer=? AND uid=?',
            [binding.issuer, binding.userId]);
        if (!valid()) throw const _PolicyStale();
        final rows = await txn.rawQuery(
            'SELECT epoch FROM policy_owner WHERE issuer=? AND uid=?',
            [binding.issuer, binding.userId]);
        if (!valid()) throw const _PolicyStale();
        if (rows.length != 1 ||
            rows.single['epoch'] is! int ||
            (rows.single['epoch'] as int) <= 0)
          throw StateError('Invalid owner state');
        return rows.single['epoch'] as int;
      });
      if (coordinator._revision[key] == revision) {
        coordinator._blocked.remove(key);
        coordinator._quarantined.remove(key);
      }
      return SqliteRevokeReceipt._(epoch);
    });
  }

  /// Returns a candidate only after checking durable marker and expiry.
  /// It is not an authorization decision.
  Future<SqliteGrantReadResult> readCandidate(
      AuthOperationScope owner, OfflineSessionBinding binding) {
    final key = _key(binding);
    final revision = coordinator._revision[key] ?? 0;
    bool current() => _current(owner, binding, revision);
    if (!current())
      return Future.value(
          const SqliteGrantReadResult(SqliteGrantReadStatus.blocked));
    return coordinator.serial(key, () async {
      if (!current())
        return const SqliteGrantReadResult(SqliteGrantReadStatus.blocked);
      try {
        DateTime? evaluatedAt, verifiedNotBefore, verifiedExpiresAt;
        final result = await coordinator.db.transaction((txn) async {
          final owners = await txn.rawQuery(
              'SELECT epoch,live_seq,state,last_seen FROM policy_owner WHERE issuer=? AND uid=?',
              [binding.issuer, binding.userId]);
          if (!current()) throw const _PolicyStale();
          if (owners.length != 1 ||
              owners.single['state'] != 'active' ||
              owners.single['epoch'] is! int ||
              (owners.single['epoch'] as int) < 0 ||
              owners.single['live_seq'] is! int ||
              (owners.single['live_seq'] as int) <= 0) {
            return const SqliteGrantReadResult(SqliteGrantReadStatus.blocked);
          }
          final rows = await txn.rawQuery(
              'SELECT owner_epoch,live_seq,checked_at,valid_until,token_nbf,token_exp FROM policy_grant '
              'WHERE issuer=? AND uid=? AND sid=?',
              [binding.issuer, binding.userId, binding.sessionId]);
          if (rows.length != 1 ||
              rows.single['owner_epoch'] != owners.single['epoch'] ||
              rows.single['live_seq'] is! int ||
              (rows.single['live_seq'] as int) <= 0 ||
              rows.single['live_seq'] != owners.single['live_seq']) {
            return const SqliteGrantReadResult(SqliteGrantReadStatus.blocked);
          }
          final grant = OfflinePolicyGrant.fromJson({
            'schema': 1,
            'issuer': binding.issuer,
            'uid': binding.userId,
            'sid': binding.sessionId,
            'checked_at': rows.single['checked_at'],
            'valid_until': rows.single['valid_until']
          }, maximumAge: OfflinePolicyGrant.maximumLocalSnapshotLifetime);
          final now = _clock().toUtc();
          evaluatedAt = now;
          DateTime? parseProof(Object? raw) {
            if (raw is! String) return null;
            final value = DateTime.tryParse(raw);
            if (value == null || !value.isUtc || value.toIso8601String() != raw)
              return null;
            return value;
          }

          verifiedNotBefore = parseProof(rows.single['token_nbf']);
          verifiedExpiresAt = parseProof(rows.single['token_exp']);
          final seenRaw = owners.single['last_seen'];
          final seen = seenRaw is String ? DateTime.tryParse(seenRaw) : null;
          if (grant == null ||
              seenRaw is! String ||
              seen == null ||
              !seen.isUtc ||
              seen.toIso8601String() != seenRaw ||
              now.isBefore(seen) ||
              verifiedNotBefore == null ||
              verifiedExpiresAt == null ||
              !grant.matchesForLocalSnapshot(binding,
                  now: now,
                  verifiedNotBefore: verifiedNotBefore,
                  verifiedExpiresAt: verifiedExpiresAt)) {
            return const SqliteGrantReadResult(SqliteGrantReadStatus.blocked);
          }
          await txn.rawUpdate(
              'UPDATE policy_owner SET last_seen=? WHERE issuer=? AND uid=?',
              [now.toIso8601String(), binding.issuer, binding.userId]);
          if (!current()) throw const _PolicyStale();
          return SqliteGrantReadResult(SqliteGrantReadStatus.found, grant);
        });
        if (!current())
          return const SqliteGrantReadResult(SqliteGrantReadStatus.blocked);
        if (result.status == SqliteGrantReadStatus.found) {
          final afterCommit = _clock().toUtc();
          if (evaluatedAt == null ||
              afterCommit.isBefore(evaluatedAt!) ||
              result.grant == null ||
              verifiedNotBefore == null ||
              verifiedExpiresAt == null ||
              !result.grant!.matchesForLocalSnapshot(binding,
                  now: afterCommit,
                  verifiedNotBefore: verifiedNotBefore,
                  verifiedExpiresAt: verifiedExpiresAt)) {
            return const SqliteGrantReadResult(SqliteGrantReadStatus.blocked);
          }
        }
        return result;
      } on _PolicyStale {
        return const SqliteGrantReadResult(SqliteGrantReadStatus.blocked);
      } catch (_) {
        return const SqliteGrantReadResult(SqliteGrantReadStatus.unavailable);
      }
    });
  }

  /// Snapshot the exact active grant before a refresh may enter the transport.
  Future<SqlitePriorGrantReceipt?> capturePriorGrant(
      AuthOperationScope owner, OfflineSessionBinding binding) async {
    final candidate = await readCandidate(owner, binding);
    if (candidate.status != SqliteGrantReadStatus.found ||
        candidate.grant == null) return null;
    final key = _key(binding),
        revision = coordinator._revision[_key(binding)] ?? 0;
    bool current() => _current(owner, binding, revision);
    return coordinator.serial(key, () async {
      if (!current()) return null;
      try {
        return await coordinator.db.transaction((txn) async {
          final owners = await txn.rawQuery(
              'SELECT epoch,live_seq,state,last_seen FROM policy_owner WHERE issuer=? AND uid=?',
              [binding.issuer, binding.userId]);
          final rows = await txn.rawQuery(
              'SELECT owner_epoch,live_seq,checked_at,valid_until,token_nbf,token_exp FROM policy_grant WHERE issuer=? AND uid=? AND sid=?',
              [binding.issuer, binding.userId, binding.sessionId]);
          if (!current() ||
              owners.length != 1 ||
              rows.length != 1 ||
              owners.single['state'] != 'active' ||
              owners.single['epoch'] is! int ||
              owners.single['live_seq'] is! int ||
              rows.single['owner_epoch'] != owners.single['epoch'] ||
              rows.single['live_seq'] != owners.single['live_seq'] ||
              rows.single['checked_at'] !=
                  candidate.grant!.checkedAt.toUtc().toIso8601String() ||
              rows.single['valid_until'] !=
                  candidate.grant!.validUntil.toUtc().toIso8601String())
            return null;
          return SqlitePriorGrantReceipt._(
              _issuer,
              owner,
              binding,
              owners.single['epoch'] as int,
              owners.single['live_seq'] as int,
              rows.single['checked_at'],
              rows.single['valid_until'],
              rows.single['token_nbf'],
              rows.single['token_exp']);
        });
      } catch (_) {
        return null;
      }
    });
  }

  /// Narrow CAS primitive. Caller MUST first close all dispatch for this owner,
  /// await the SDK single-flight AND every underlying request, and prove a
  /// transport outage with no denial/security-fence failure. A timeout or a
  /// crash cannot supply that evidence. This method alone grants no capability.
  Future<bool> restoreAfterSettledTransportFailure(
      SqlitePriorGrantReceipt prior, SqliteLiveGrantAttempt latest) {
    if (!identical(prior._issuer, _issuer) ||
        !identical(latest._issuer, _issuer) ||
        prior._used ||
        latest._used ||
        prior._owner != latest._owner ||
        !_same(prior._binding, latest._binding)) return Future.value(false);
    prior._used = true;
    latest._used = true;
    final binding = prior._binding;
    bool current() => _current(latest._owner, binding, latest._memoryRevision);
    return coordinator.serial(_key(binding), () async {
      if (!current()) return false;
      try {
        return await coordinator.db.transaction((txn) async {
          final owners = await txn.rawQuery(
              'SELECT epoch,live_seq,state,last_seen FROM policy_owner WHERE issuer=? AND uid=?',
              [binding.issuer, binding.userId]);
          final rows = await txn.rawQuery(
              'SELECT owner_epoch,live_seq,checked_at,valid_until,token_nbf,token_exp FROM policy_grant WHERE issuer=? AND uid=? AND sid=?',
              [binding.issuer, binding.userId, binding.sessionId]);
          if (!current() ||
              owners.length != 1 ||
              rows.length != 1 ||
              owners.single['state'] != 'revoked' ||
              owners.single['epoch'] != prior._epoch ||
              owners.single['epoch'] != latest._durableEpoch ||
              owners.single['live_seq'] != latest._liveSequence ||
              latest._liveSequence <= prior._sequence ||
              rows.single['owner_epoch'] != prior._epoch ||
              rows.single['live_seq'] != prior._sequence ||
              rows.single['checked_at'] != prior._checkedAt ||
              rows.single['valid_until'] != prior._validUntil ||
              rows.single['token_nbf'] != prior._tokenNbf ||
              rows.single['token_exp'] != prior._tokenExp) return false;
          final updated = await txn.rawUpdate(
              'UPDATE policy_grant SET live_seq=? WHERE issuer=? AND uid=? AND sid=? AND owner_epoch=? AND live_seq=?',
              [
                latest._liveSequence,
                binding.issuer,
                binding.userId,
                binding.sessionId,
                prior._epoch,
                prior._sequence
              ]);
          if (updated != 1 || !current()) throw const _PolicyStale();
          final activated = await txn.rawUpdate(
              'UPDATE policy_owner SET state=? WHERE issuer=? AND uid=? AND epoch=? AND live_seq=?',
              [
                'active',
                binding.issuer,
                binding.userId,
                prior._epoch,
                latest._liveSequence
              ]);
          if (activated != 1 || !current()) throw const _PolicyStale();
          return true;
        });
      } on _PolicyStale {
        return false;
      }
    });
  }

  void dispose() => _disposed = true;
}
