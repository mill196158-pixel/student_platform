import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/guarded_database.dart';

/// Experimental identity coordination only; it never authenticates a session.
/// Every auth transition and every reader must participate before runtime use.
class DurableActiveSessionRegistry {
  DurableActiveSessionRegistry(this.db, String project)
      : project = _canonicalProject(project);
  final Database db;
  final String project;
  final Object _issuer = Object();

  static String _canonicalProject(String value) {
    final uri = Uri.tryParse(value);
    if (value != value.trim() ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError.value(
          value, 'project', 'Expected an HTTPS project origin');
    }
    return uri.origin;
  }

  Future<void> initialize() async {
    if (project.isEmpty) throw ArgumentError('project');
    await db.execute('CREATE TABLE IF NOT EXISTS active_session_registry ('
        'project TEXT PRIMARY KEY NOT NULL, instance TEXT NOT NULL, revision INTEGER NOT NULL, '
        'state TEXT NOT NULL, uid TEXT, sid TEXT, transition TEXT, '
        'next_uid TEXT, next_sid TEXT)');
    final random = Random.secure();
    final instance =
        base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    await db.insert(
        'active_session_registry',
        {
          'project': project,
          'instance': instance,
          'revision': 0,
          'state': 'empty'
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<ActiveSessionSnapshot?> read() async {
    try {
      final rows = await db.query('active_session_registry',
          where: 'project=?', whereArgs: [project]);
      if (rows.length != 1) return null;
      final row = rows.single;
      final state = row['state'],
          revision = row['revision'],
          instance = row['instance'];
      if (instance is! String ||
          instance.isEmpty ||
          revision is! int ||
          revision < 0 ||
          !const {'empty', 'active', 'transition'}.contains(state)) return null;
      final uid = row['uid'], sid = row['sid'];
      if (state == 'active' &&
          (uid is! String || uid.isEmpty || sid is! String || sid.isEmpty))
        return null;
      if (state == 'empty' && (uid != null || sid != null)) return null;
      return ActiveSessionSnapshot._(
          _issuer,
          instance,
          revision,
          state as String,
          uid is String ? uid : null,
          sid is String ? sid : null);
    } catch (_) {
      return null;
    }
  }

  /// Call before dispatching any change to the SDK session. A crash or
  /// ambiguous SDK outcome leaves `transition` blocked, never the old owner.
  Future<ActiveSessionTransition?> begin(ActiveSessionSnapshot expected,
      {String? nextUid,
      String? nextSid,
      required bool Function() current}) async {
    if (!identical(expected._issuer, _issuer) ||
        expected.state == 'transition' ||
        ((nextUid == null) != (nextSid == null)) ||
        (nextUid != null && (nextUid.isEmpty || nextSid!.isEmpty)) ||
        !current()) return null;
    final random = Random.secure();
    final token =
        base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
    try {
      final accepted = await db.transaction((txn) async {
        if (!current()) return false;
        final count = await txn.rawUpdate(
            'UPDATE active_session_registry '
            'SET revision=revision+1, state=?, transition=?, next_uid=?, next_sid=? '
            'WHERE project=? AND instance=? AND revision=? AND state=? AND uid IS ? AND sid IS ?',
            [
              'transition',
              token,
              nextUid,
              nextSid,
              project,
              expected.instance,
              expected.revision,
              expected.state,
              expected.uid,
              expected.sid
            ]);
        if (!current()) throw StateError('stale transition');
        return count == 1;
      });
      return accepted && current()
          ? ActiveSessionTransition._(_issuer, expected.instance, token,
              expected.revision + 1, nextUid, nextSid)
          : null;
    } catch (_) {
      return null;
    }
  }

  /// The caller independently verifies the SDK result and current authority.
  /// On uncertainty do not call this: the pending intent must remain blocked.
  Future<bool> finish(ActiveSessionTransition ticket,
      {required bool Function() current}) async {
    if (!identical(ticket._issuer, _issuer) || !current()) return false;
    try {
      return await db.transaction((txn) async {
        if (!current()) return false;
        final count = await txn.rawUpdate(
            'UPDATE active_session_registry '
            'SET revision=revision+1, state=?, uid=?, sid=?, transition=NULL, next_uid=NULL, next_sid=NULL '
            'WHERE project=? AND instance=? AND revision=? AND state=? AND transition=? AND next_uid IS ? AND next_sid IS ?',
            [
              ticket.nextUid == null ? 'empty' : 'active',
              ticket.nextUid,
              ticket.nextSid,
              project,
              ticket.instance,
              ticket.revision,
              'transition',
              ticket._token,
              ticket.nextUid,
              ticket.nextSid
            ]);
        if (!current()) throw StateError('stale transition');
        return count == 1;
      });
    } catch (_) {
      return false;
    }
  }

  /// May be called in the same transaction as native dispatch. Equality of
  /// UID/SID is not a substitute for the caller's current authorization.
  Future<bool> permitsInTransaction(
      Transaction txn, ActiveSessionSnapshot snapshot,
      {required String uid, required String sid}) async {
    if (!identical(snapshot._issuer, _issuer) ||
        snapshot.state != 'active' ||
        snapshot.uid != uid ||
        snapshot.sid != sid) return false;
    try {
      // A matching row in a different database is not evidence. Require the
      // exact connection, not just the same path or a copied registry file.
      final expected = db is GuardedDatabase
          ? (db as GuardedDatabase).inner.database
          : db.database;
      if (!identical(txn.database, expected) || !db.isOpen) return false;
      final rows = await txn.query('active_session_registry',
          columns: ['revision'],
          where:
              'project=? AND instance=? AND state=? AND revision=? AND uid=? AND sid=?',
          whereArgs: [
            project,
            snapshot.instance,
            'active',
            snapshot.revision,
            uid,
            sid
          ]);
      return rows.length == 1;
    } catch (_) {
      return false;
    }
  }
}

class ActiveSessionSnapshot {
  const ActiveSessionSnapshot._(this._issuer, this.instance, this.revision,
      this.state, this.uid, this.sid);
  final Object _issuer;
  final String instance;
  final int revision;
  final String state;
  final String? uid, sid;
}

class ActiveSessionTransition {
  const ActiveSessionTransition._(this._issuer, this.instance, this._token,
      this.revision, this.nextUid, this.nextSid);
  final Object _issuer;
  final String instance;
  final String _token;
  final int revision;
  final String? nextUid, nextSid;
}
