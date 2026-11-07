import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Durable write-ahead fences for network checks of an archived attachment.
/// An unresolved check survives process death and conservatively blocks reads.
class PinnedAccessFence {
  @visibleForTesting
  static int debugFailMutationAttempts = 0;
  PinnedAccessFence(this.db, {this.databaseToken});
  final Database db;
  final String? databaseToken;
  String _id(String project, String uid, String key) =>
      sha256.convert(utf8.encode(jsonEncode([project, uid, key]))).toString();

  Future<void> _tables(Transaction txn) async {
    await txn.execute('CREATE TABLE IF NOT EXISTS pinned_fence_state ('
        'id TEXT PRIMARY KEY, revision INTEGER NOT NULL, denied INTEGER NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, content_hash TEXT)');
    final stateColumns = await txn.rawQuery('PRAGMA table_info(pinned_fence_state)');
    if (!stateColumns.any((row) => row['name'] == 'dirty')) {
      await txn.execute('ALTER TABLE pinned_fence_state ADD COLUMN dirty INTEGER NOT NULL DEFAULT 1');
    }
    if (!stateColumns.any((row) => row['name'] == 'content_hash')) {
      await txn.execute('ALTER TABLE pinned_fence_state ADD COLUMN content_hash TEXT');
    }
    await txn.execute('CREATE TABLE IF NOT EXISTS pinned_fence_pending ('
        'token TEXT PRIMARY KEY, id TEXT NOT NULL, revision INTEGER NOT NULL, database_token TEXT NOT NULL)');
    final columns = await txn.rawQuery('PRAGMA table_info(pinned_fence_pending)');
    if (!columns.any((row) => row['name'] == 'database_token')) {
      await txn.execute("ALTER TABLE pinned_fence_pending ADD COLUMN database_token TEXT NOT NULL DEFAULT ''");
    }
  }

  Future<String> begin(String project, String uid, String key) async {
    final id = _id(project, uid, key);
    final random = Random.secure();
    final token = base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
    await db.transaction((txn) async {
      await _tables(txn);
      if (databaseToken == null || databaseToken!.isEmpty ||
          (await txn.query('chat_app_guards', columns: ['token'],
            where: 'token=? AND project=? AND sid=?', whereArgs: [databaseToken, '*', ''])).length != 1) {
        throw StateError('A live guarded database handle is required');
      }
      await txn.insert('pinned_fence_state', {'id': id, 'revision': 0, 'denied': 0},
          conflictAlgorithm: ConflictAlgorithm.ignore);
      final row = (await txn.query('pinned_fence_state', where: 'id=?', whereArgs: [id])).single;
      await txn.insert('pinned_fence_pending', {'token': token, 'id': id,
        'revision': row['revision'], 'database_token': databaseToken});
    });
    return token;
  }

  /// Only call when the exact handle is closed or its OS lock proves death.
  /// Mark unknown outcomes denied; a later exclusive live check may restore.
  static Future<void> recoverHandle(Transaction txn, String databaseToken) async {
    final tables = await txn.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='pinned_fence_pending'");
    if (tables.isEmpty) return;
    final columns = await txn.rawQuery('PRAGMA table_info(pinned_fence_pending)');
    if (!columns.any((row) => row['name'] == 'database_token')) return;
    await txn.rawUpdate('UPDATE pinned_fence_state SET denied=1, dirty=1, revision=revision+1 '
        'WHERE id IN (SELECT id FROM pinned_fence_pending WHERE database_token=?)', [databaseToken]);
    await txn.delete('pinned_fence_pending', where: 'database_token=?', whereArgs: [databaseToken]);
  }

  /// Call in the same transaction as a legacy source replacement. The old
  /// archived version stays on disk but cannot be shown until revalidated.
  Future<void> markChanged(Transaction txn, String project, String uid, String key) async {
    await _tables(txn);
    final id = _id(project, uid, key);
    await txn.insert('pinned_fence_state', {'id': id, 'revision': 0, 'denied': 1},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.rawUpdate('UPDATE pinned_fence_state SET denied=1, dirty=1, revision=revision+1 WHERE id=?', [id]);
  }

  /// Called only in the same transaction as verified proof publication.
  Future<void> markPinned(Transaction txn, String project, String uid, String key, String checksum) async {
    await _tables(txn);
    final id = _id(project, uid, key);
    await txn.insert('pinned_fence_state', {'id': id, 'revision': 0, 'denied': 1, 'dirty': 0},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await txn.update('pinned_fence_state', {'dirty': 0, 'content_hash': checksum}, where: 'id=?', whereArgs: [id]);
  }

  /// A transport failure preserves the prior state. A verified allow may
  /// clear an older denial only if no newer denial happened after it began.
  Future<void> finish(String token, {required bool? allowed}) async {
    await db.transaction((txn) async {
      await _tables(txn);
      final rows = await txn.query('pinned_fence_pending', where: 'token=?', whereArgs: [token]);
      if (rows.length != 1) return;
      final pending = rows.single, id = pending['id'] as String;
      if (allowed == false) {
        await txn.rawUpdate('UPDATE pinned_fence_state SET denied=1, revision=revision+1 WHERE id=?', [id]);
      } else if (allowed == true) {
        await txn.update('pinned_fence_state', {'denied': 0},
            where: 'id=? AND revision=?', whereArgs: [id, pending['revision']]);
      }
      await txn.delete('pinned_fence_pending', where: 'token=?', whereArgs: [token]);
    });
  }

  /// Mutation outcome is uncertain: persist dirty denial before releasing
  /// the pending token. If persistence fails the pending token remains.
  Future<void> failMutation(String token) async {
    if (debugFailMutationAttempts > 0) {
      debugFailMutationAttempts--;
      throw StateError('Injected mutation fence failure');
    }
    await db.transaction((txn) async {
      await _tables(txn);
      final rows = await txn.query('pinned_fence_pending', where: 'token=?', whereArgs: [token]);
      if (rows.length != 1) return;
      await txn.rawUpdate('UPDATE pinned_fence_state SET denied=1, dirty=1, revision=revision+1 WHERE id=?', [rows.single['id']]);
      await txn.delete('pinned_fence_pending', where: 'token=?', whereArgs: [token]);
    });
  }

  Future<bool> canRead(String project, String uid, String key, {String? checksum}) async {
    try {
      return await db.transaction((txn) => canReadInTransaction(txn, project, uid, key, checksum: checksum));
    } catch (_) { return false; }
  }

  Future<bool> canReadInTransaction(Transaction txn, String project, String uid,
      String key, {String? checksum}) async {
    await _tables(txn);
    final id = _id(project, uid, key);
    final rows = await txn.query('pinned_fence_state', where: 'id=?', whereArgs: [id]);
    if (rows.length != 1 || rows.single['denied'] != 0 || rows.single['dirty'] != 0 ||
        (checksum != null && rows.single['content_hash'] != checksum)) return false;
    return (await txn.query('pinned_fence_pending', columns: ['token'],
        where: 'id=?', whereArgs: [id], limit: 1)).isEmpty;
  }

  /// A legacy copy can predate this DB. Its own session receipt is checked by
  /// the caller in this same transaction; any recorded denial or pending
  /// access check still blocks dispatch.
  Future<bool> canReadLegacyInTransaction(Transaction txn, String project, String uid, String key) async {
    await _tables(txn);
    final id = _id(project, uid, key);
    final rows = await txn.query('pinned_fence_state', where: 'id=?', whereArgs: [id]);
    if (rows.length > 1 || (rows.isNotEmpty && rows.single['denied'] != 0)) return false;
    return (await txn.query('pinned_fence_pending', columns: ['token'],
        where: 'id=?', whereArgs: [id], limit: 1)).isEmpty;
  }

  /// Internal comparison only; never authorizes display or suppresses deny.
  Future<bool> isContentClean(String project, String uid, String key) async {
    try {
      return await db.transaction((txn) async {
        await _tables(txn);
        final rows = await txn.query('pinned_fence_state', columns: ['dirty'],
            where: 'id=?', whereArgs: [_id(project, uid, key)]);
        return rows.length == 1 && rows.single['dirty'] == 0;
      });
    } catch (_) { return false; }
  }
}
