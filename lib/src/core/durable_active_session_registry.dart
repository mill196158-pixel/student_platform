import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/guarded_database.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

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
        'next_uid TEXT, next_sid TEXT, owner_engine TEXT)');
    await db.execute('CREATE TABLE IF NOT EXISTS qa_session_credentials ('
        'project TEXT PRIMARY KEY, instance TEXT NOT NULL, revision INTEGER NOT NULL, digest TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS qa_auth_session ('
        'project TEXT PRIMARY KEY, session TEXT NOT NULL)');
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
          !const {'empty', 'active', 'transition', 'revoked'}.contains(state)) return null;
      final uid = row['uid'], sid = row['sid'];
      if ((state == 'active' || state == 'revoked') &&
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
      {required bool Function() current, ProjectDatabaseOwnerCapability? handoffOwner}) async {
    if (!identical(ticket._issuer, _issuer) || !current()) return false;
    final handoffOwnerToken = handoffOwner?.tokenFor(db);
    if (handoffOwner != null && handoffOwnerToken == null) return false;
    if (handoffOwnerToken != null && (handoffOwnerToken.isEmpty || ticket.nextUid == null)) return false;
    try {
      return await db.transaction((txn) async {
        if (!current()) return false;
        if (handoffOwnerToken != null) {
          final guard = await txn.query('chat_app_guards', columns: ['token'],
              where: 'token=? AND project=? AND sid=?', whereArgs: [handoffOwnerToken, '*', '']);
          if (guard.length != 1 || !current() || !handoffOwner!.isCurrentFor(db)) return false;
        }
        final count = await txn.rawUpdate(
            'UPDATE active_session_registry '
            'SET revision=revision+1, state=?, uid=?, sid=?, owner_engine=?, transition=NULL, next_uid=NULL, next_sid=NULL '
            'WHERE project=? AND instance=? AND revision=? AND state=? AND transition=? AND next_uid IS ? AND next_sid IS ?',
            [
              ticket.nextUid == null ? 'empty' : 'active',
              ticket.nextUid,
              ticket.nextSid,
              handoffOwnerToken,
              project,
              ticket.instance,
              ticket.revision,
              'transition',
              ticket._token,
              ticket.nextUid,
              ticket.nextSid
            ]);
        if (!current() || (handoffOwner != null && !handoffOwner.isCurrentFor(db))) {
          throw StateError('stale transition');
        }
        return count == 1;
      });
    } catch (_) {
      return false;
    }
  }

  /// Terminal denial of this exact pending transition. An unrelated or newer
  /// transition cannot be revoked by a late response.
  Future<bool> denyTransition(ActiveSessionTransition ticket,
      {required bool Function() current}) async {
    if (!identical(ticket._issuer, _issuer) || ticket.nextUid == null ||
        ticket.nextSid == null || !current()) return false;
    try {
      return await db.transaction((txn) async {
        if (!current()) return false;
        final changed = await txn.rawUpdate(
            'UPDATE active_session_registry SET revision=revision+1, state=?, '
            'owner_engine=NULL, transition=NULL, next_uid=NULL, next_sid=NULL '
            'WHERE project=? AND instance=? AND revision=? AND state=? AND transition=? '
            'AND uid IS ? AND sid IS ?',
            ['revoked', project, ticket.instance, ticket.revision, 'transition',
              ticket._token, ticket.nextUid, ticket.nextSid]);
        if (!current()) throw StateError('stale denial');
        return changed == 1;
      });
    } catch (_) { return false; }
  }

  /// A verified terminal refusal invalidates only the exact captured owner
  /// and generation. Socket outages must never call this operation.
  Future<bool> revoke(ActiveSessionSnapshot snapshot, {required bool Function() current}) async {
    if (!identical(snapshot._issuer, _issuer) || snapshot.state != 'active' || !current()) return false;
    try {
      return await db.transaction((txn) async {
        if (!current()) return false;
        final changed = await txn.rawUpdate('UPDATE active_session_registry '
            'SET revision=revision+1, state=?, owner_engine=NULL '
            'WHERE project=? AND instance=? AND revision=? AND state=? AND uid=? AND sid=?',
            ['revoked', project, snapshot.instance, snapshot.revision, 'active', snapshot.uid, snapshot.sid]);
        return changed == 1;
      });
    } catch (_) { return false; }
  }

  /// Same account/SID with newly confirmed credentials is not an account
  /// switch, but advances the fence so an older response cannot revoke it.
  Future<bool> advanceCredentials(ActiveSessionSnapshot snapshot,
      {required bool Function() current}) async {
    if (!identical(snapshot._issuer, _issuer) || snapshot.state != 'active' || !current()) return false;
    try {
      return await db.transaction((txn) async {
        if (!current()) return false;
        final changed = await txn.rawUpdate('UPDATE active_session_registry SET revision=revision+1 '
            'WHERE project=? AND instance=? AND revision=? AND state=? AND uid=? AND sid=?',
            [project, snapshot.instance, snapshot.revision, 'active', snapshot.uid, snapshot.sid]);
        if (!current()) throw StateError('stale credential rotation');
        return changed == 1;
      });
    } catch (_) { return false; }
  }

  /// Native handoff is permitted only for the engine bound at admission. A
  /// persisted guard row alone does not prove that an OS process is alive;
  /// recovery must separately establish guard ownership and must not use timeouts.
  Future<bool> permitsHandoffInTransaction(Transaction txn, ActiveSessionSnapshot snapshot,
      {required String uid, required String sid, required ProjectDatabaseOwnerCapability owner}) async {
    final engineToken = owner.tokenFor(db);
    if (engineToken == null || !await permitsInTransaction(txn, snapshot, uid: uid, sid: sid)) return false;
    try {
      final rows = await txn.query('active_session_registry', columns: ['owner_engine'],
          where: 'project=? AND instance=? AND revision=? AND state=? AND uid=? AND sid=? AND owner_engine=?',
          whereArgs: [project, snapshot.instance, snapshot.revision, 'active', uid, sid, engineToken]);
      if (rows.length != 1) return false;
      final guards = await txn.query('chat_app_guards', columns: ['token'],
          where: 'token=? AND project=? AND sid=?', whereArgs: [engineToken, '*', '']);
      return guards.length == 1 && owner.isCurrentFor(db);
    } catch (_) { return false; }
  }

  /// Experimental exact transition and handle check for guarded SDK storage.
  Future<bool> permitsTransitionInTransaction(Transaction txn, ActiveSessionTransition ticket,
      {required ProjectDatabaseOwnerCapability owner}) async {
    if (!identical(ticket._issuer, _issuer)) return false;
    final expected = db is GuardedDatabase ? (db as GuardedDatabase).inner.database : db.database;
    final token = owner.tokenFor(db);
    if (!identical(txn.database, expected) || token == null || !db.isOpen) return false;
    try {
      final rows = await txn.query('active_session_registry', columns: ['revision'],
          where: 'project=? AND instance=? AND revision=? AND state=? AND transition=? AND owner_engine=?',
          whereArgs: [project, ticket.instance, ticket.revision, 'transition', ticket._token, token]);
      if (rows.length != 1 || !owner.isCurrentFor(db)) return false;
      final guards = await txn.query('chat_app_guards', columns: ['token'],
          where: 'token=? AND project=? AND sid=?', whereArgs: [token, '*', '']);
      return guards.length == 1 && owner.isCurrentFor(db);
    } catch (_) { return false; }
  }

  /// QA login starts without a known UID/SID; assign owner only to its exact
  /// committed ticket, then bind the server-confirmed identity before writes.
  Future<bool> claimLoginTransition(ActiveSessionTransition ticket,
      ProjectDatabaseOwnerCapability owner) async {
    if (!identical(ticket._issuer, _issuer) || ticket.nextUid != null || ticket.nextSid != null) return false;
    final token = owner.tokenFor(db);
    if (token == null) return false;
    try {
      return await db.transaction((txn) async {
        final guards = await txn.query('chat_app_guards', columns:['token'],
          where:'token=? AND project=? AND sid=?', whereArgs:[token,'*','']);
        if (guards.length != 1 || !owner.isCurrentFor(db)) return false;
        final n = await txn.rawUpdate('UPDATE active_session_registry SET owner_engine=? '
          'WHERE project=? AND instance=? AND revision=? AND state=? AND transition=? AND owner_engine IS NULL AND uid IS NULL AND sid IS NULL',
          [token,project,ticket.instance,ticket.revision,'transition',ticket._token]);
        return n == 1 && owner.isCurrentFor(db);
      });
    } catch (_) { return false; }
  }

  Future<ActiveSessionTransition?> bindLoginIdentity(ActiveSessionTransition ticket,
      ProjectDatabaseOwnerCapability owner, {required String uid, required String sid}) async {
    if (uid.isEmpty || sid.isEmpty || ticket.nextUid != null || ticket.nextSid != null) return null;
    try {
      return await db.transaction((txn) async {
        if (!await permitsTransitionInTransaction(txn, ticket, owner:owner)) return null;
        final n = await txn.rawUpdate('UPDATE active_session_registry SET revision=revision+1,next_uid=?,next_sid=? '
          'WHERE project=? AND instance=? AND revision=? AND state=? AND transition=? AND next_uid IS NULL AND next_sid IS NULL',
          [uid,sid,project,ticket.instance,ticket.revision,'transition',ticket._token]);
        return n == 1 ? ActiveSessionTransition._(_issuer,ticket.instance,ticket._token,ticket.revision+1,uid,sid) : null;
      });
    } catch (_) { return null; }
  }

  /// QA only: the storage read and registry publication are serialized by
  /// the same SQLite write transaction. Every participating writer must lock
  /// the database before entering its storage queue.
  Future<bool> finishWithCredential(ActiveSessionTransition ticket,
      {required ProjectDatabaseOwnerCapability owner,
      required Future<String?> Function(Transaction) readDigest,
      required bool Function() current}) async {
    if (ticket.nextUid == null || ticket.nextSid == null) return false;
    try {
      return await db.transaction((txn) async {
        if (!current() || !await permitsTransitionInTransaction(txn, ticket, owner: owner)) return false;
        final digest = await readDigest(txn);
        if (digest == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
            !current() || !await permitsTransitionInTransaction(txn, ticket, owner: owner)) return false;
        final changed = await txn.rawUpdate('UPDATE active_session_registry SET revision=revision+1, state=?, uid=?, sid=?, transition=NULL, next_uid=NULL, next_sid=NULL '
            'WHERE project=? AND instance=? AND revision=? AND state=? AND transition=?',
            ['active', ticket.nextUid, ticket.nextSid, project, ticket.instance, ticket.revision, 'transition', ticket._token]);
        if (changed != 1) throw StateError('stale transition');
        await txn.insert('qa_session_credentials', {'project':project, 'instance':ticket.instance,
          'revision':ticket.revision + 1, 'digest':digest}, conflictAlgorithm: ConflictAlgorithm.replace);
        if (!owner.isCurrentFor(db) || !current()) throw StateError('owner lost');
        return true;
      });
    } catch (_) { return false; }
  }

  Future<bool> credentialMatchesInTransaction(Transaction txn, ActiveSessionSnapshot snapshot, String digest,
      {required ProjectDatabaseOwnerCapability owner}) async {
    if (snapshot.uid == null || snapshot.sid == null ||
        !await permitsHandoffInTransaction(txn, snapshot, uid:snapshot.uid!, sid:snapshot.sid!, owner:owner)) return false;
    final rows = await txn.query('qa_session_credentials', columns:['digest'],
      where:'project=? AND instance=? AND revision=? AND digest=?',
      whereArgs:[project,snapshot.instance,snapshot.revision,digest]);
    return rows.length == 1;
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
