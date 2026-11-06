import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';

/// Append-only protected recovery snapshots. Journal entries never overwrite a
/// current draft and are offered only after explicit owner-scoped recovery.
class DraftRecoveryJournal {
  DraftRecoveryJournal({Future<Database> Function()? open})
      : _open = open ?? _openDefault;
  final Future<Database> Function() _open;
  @visibleForTesting
  static Future<Database> Function()? debugOpen;
  static Future<Database>? _defaultDatabase;
  static const maxEntries = 128;
  static const maxOwnerEntries = 16;
  static const maxBytes = 4 * 1024 * 1024;

  static Future<Database> _openDefault() {
    if (kDebugMode && debugOpen != null) return debugOpen!();
    return _defaultDatabase ??= () async {
        final dir = await getDatabasesPath();
        return openDatabase('$dir/draft_recovery_v1.db', version: 1,
            onCreate: (db, _) => _create(db));
      }();
  }

  static Future<void> _create(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS draft_recovery (
      operation_id TEXT PRIMARY KEY, project TEXT NOT NULL, owner TEXT NOT NULL,
      session_id TEXT NOT NULL, conversation TEXT NOT NULL, payload TEXT NOT NULL,
      payload_bytes INTEGER NOT NULL, created_us INTEGER NOT NULL,
      resolved INTEGER NOT NULL DEFAULT 0
    )
  ''');

  Future<bool> append({required String project, required String owner,
      required String sessionId, required String conversation,
      required Map<String, dynamic> draft, required bool Function() permitted}) async {
    if (!permitted() || [project, owner, sessionId, conversation].any((v) => v.isEmpty)) return false;
    final payload = jsonEncode(draft);
    final bytes = utf8.encode(payload).length;
    if (bytes > maxBytes) return false;
    final random = Random.secure();
    final operation = '${DateTime.now().microsecondsSinceEpoch}-${List.generate(4, (_) => random.nextInt(0x100000000)).join('-')}';
    final database = await _open();
    if (!permitted()) return false;
    await _create(database);
    return database.transaction((transaction) async {
      if (!permitted()) return false;
      // Only snapshots explicitly recovered into a confirmed canonical draft
      // are eligible for space reclamation. Unfinished entries never are.
      final totalsBefore = (await transaction.rawQuery(
          'SELECT COUNT(*) AS n, COALESCE(SUM(payload_bytes),0) AS bytes FROM draft_recovery')).single;
      if ((totalsBefore['n'] as int) >= maxEntries ||
          (totalsBefore['bytes'] as int) + bytes > maxBytes) {
        await transaction.delete('draft_recovery', where: 'resolved=1');
      }
      final totals = (await transaction.rawQuery(
          'SELECT COUNT(*) AS n, COALESCE(SUM(payload_bytes),0) AS bytes FROM draft_recovery')).single;
      final ownerCount = Sqflite.firstIntValue(await transaction.rawQuery(
          'SELECT COUNT(*) FROM draft_recovery WHERE project=? AND owner=? AND resolved=0', [project, owner])) ?? 0;
      if ((totals['n'] as int) >= maxEntries || ownerCount >= maxOwnerEntries ||
          (totals['bytes'] as int) + bytes > maxBytes || !permitted()) return false;
      await transaction.insert('draft_recovery', {
        'operation_id': operation, 'project': project, 'owner': owner,
        'session_id': sessionId, 'conversation': conversation, 'payload': payload,
        'payload_bytes': bytes, 'created_us': DateTime.now().microsecondsSinceEpoch,
      });
      return true;
    });
  }

  Future<List<Map<String, dynamic>>> pending({required String project,
      required String owner, required String conversation,
      required bool Function() permitted}) async {
    if (!permitted()) return [];
    final db = await _open();
    await _create(db);
    if (!permitted()) return [];
    final rows = await db.query('draft_recovery',
        columns: ['operation_id', 'payload', 'session_id'],
        where: 'project=? AND owner=? AND conversation=? AND resolved=0',
        whereArgs: [project, owner, conversation], orderBy: 'created_us DESC');
    if (!permitted()) return [];
    return rows.map((row) => {
      'operation_id': row['operation_id'], 'session_id': row['session_id'],
      'draft': jsonDecode(row['payload'] as String),
    }).toList();
  }

  Future<bool> markResolved({required String project, required String owner,
      required String conversation, required String operationId,
      required bool Function() permitted}) async {
    if (!permitted()) return false;
    final db = await _open();
    await _create(db);
    if (!permitted()) return false;
    final changed = await db.update('draft_recovery', {'resolved': 1},
        where: 'project=? AND owner=? AND conversation=? AND operation_id=? AND resolved=0',
        whereArgs: [project, owner, conversation, operationId]);
    return changed == 1 && permitted();
  }
}
