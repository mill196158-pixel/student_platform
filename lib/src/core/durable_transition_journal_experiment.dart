import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:sqflite/sqflite.dart';

/// Isolated experiment. Neither pending nor prepared is an admission grant.
/// This journal does not authenticate its caller or fence SDK/network work.
class DurableTransitionJournalExperiment {
  DurableTransitionJournalExperiment(this.db);
  final Database db;
  final Object _issuer = Object();

  @visibleForTesting
  Future<void> Function()? debugBeforePrepareReturn;

  /// Explicit setup for an isolated test database; never called by app startup.
  static Future<void> createForExperiment(Database db) => db.execute('''
    CREATE TABLE transition_experiment (
      project TEXT PRIMARY KEY NOT NULL,
      epoch INTEGER NOT NULL CHECK(epoch > 0),
      uid TEXT NOT NULL,
      sid TEXT NOT NULL,
      state TEXT NOT NULL CHECK(state IN ('pending', 'prepared', 'revoked')),
      snapshot BLOB,
      CHECK((state = 'prepared' AND snapshot IS NOT NULL) OR
            (state <> 'prepared' AND snapshot IS NULL))
    )
  ''');

  bool _current(bool Function() guard) {
    try { return guard(); } catch (_) { return false; }
  }

  /// The epoch is global within a project, not per user. A caller-supplied
  /// guard is not transition evidence and must not be used as authorization.
  Future<TransitionExperimentTicket?> begin({required String project,
      required String uid, required String sid, required bool Function() isCurrent}) async {
    if ([project, uid, sid].any((s) => s.isEmpty || s.length > 1024) ||
        !_current(isCurrent)) return null;
    try {
      return await db.transaction((txn) async {
        if (!_current(isCurrent)) throw const _StaleTransition();
        final existing = await txn.query('transition_experiment',
            columns: ['epoch'], where: 'project = ?', whereArgs: [project]);
        if (!_current(isCurrent)) throw const _StaleTransition();
        final previous = existing.isEmpty ? 0 : existing.single['epoch'];
        if (previous is! int || previous < 0 || previous >= 0x7ffffffffffffffe) {
          throw const _StaleTransition();
        }
        final epoch = previous + 1;
        if (existing.isEmpty) {
          await txn.insert('transition_experiment', {'project': project, 'epoch': epoch,
            'uid': uid, 'sid': sid, 'state': 'pending', 'snapshot': null});
        } else {
          await txn.update('transition_experiment', {'epoch': epoch, 'uid': uid,
            'sid': sid, 'state': 'pending', 'snapshot': null},
            where: 'project = ? AND epoch = ?', whereArgs: [project, previous]);
        }
        if (!_current(isCurrent)) throw const _StaleTransition();
        return TransitionExperimentTicket._(_issuer, project, uid, sid, epoch);
      });
    } catch (_) { return null; }
  }

  /// Stores only a prepared snapshot; it can never issue an offline permit.
  Future<bool> prepare(TransitionExperimentTicket ticket, Uint8List snapshot,
      {required bool Function() isCurrent}) async {
    if (!identical(ticket._issuer, _issuer) || snapshot.isEmpty ||
        snapshot.length > 65536 || !_current(isCurrent)) return false;
    final immutable = Uint8List.fromList(snapshot);
    try {
      return await db.transaction((txn) async {
        if (!_current(isCurrent)) throw const _StaleTransition();
        final changed = await txn.update('transition_experiment',
            {'state': 'prepared', 'snapshot': immutable},
            where: 'project = ? AND epoch = ? AND uid = ? AND sid = ? AND state = ?',
            whereArgs: [ticket.project, ticket.epoch, ticket.uid, ticket.sid, 'pending']);
        if (!_current(isCurrent)) throw const _StaleTransition();
        if (kDebugMode) await debugBeforePrepareReturn?.call();
        if (!_current(isCurrent)) throw const _StaleTransition();
        if (changed != 1) throw const _StaleTransition();
        return true;
      });
    } catch (_) { return false; }
  }

  /// A stale owner cannot revoke a later owner's transition.
  Future<bool> revoke(TransitionExperimentTicket ticket,
      {required bool Function() isCurrent}) async {
    if (!identical(ticket._issuer, _issuer) || !_current(isCurrent) ||
        ticket.epoch >= 0x7ffffffffffffffe) return false;
    try {
      return await db.transaction((txn) async {
        if (!_current(isCurrent)) throw const _StaleTransition();
        final changed = await txn.update('transition_experiment',
            {'epoch': ticket.epoch + 1, 'state': 'revoked', 'snapshot': null},
            where: 'project = ? AND epoch = ? AND uid = ? AND sid = ?',
            whereArgs: [ticket.project, ticket.epoch, ticket.uid, ticket.sid]);
        if (!_current(isCurrent) || changed != 1) throw const _StaleTransition();
        return true;
      });
    } catch (_) { return false; }
  }
}

class TransitionExperimentTicket {
  const TransitionExperimentTicket._(this._issuer, this.project, this.uid, this.sid, this.epoch);
  final Object _issuer;
  final String project, uid, sid;
  final int epoch;
}

class _StaleTransition implements Exception { const _StaleTransition(); }
