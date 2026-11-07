import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

/// Admission for cooperating optional-media writers only. This is not a
/// global disk quota: the caller must inventory every covered physical file.
/// A crash deliberately leaves reservations in place; this class never deletes
/// media or guesses that a crashed writer is safe to release.
class DurableOptionalMediaReservations {
  const DurableOptionalMediaReservations(this.db);
  final Database db;

  static Future<void> createSchema(Database db) => db.execute(
      'CREATE TABLE IF NOT EXISTS optional_media_reservations '
      '(token TEXT PRIMARY KEY NOT NULL, bytes INTEGER NOT NULL CHECK(bytes>0))');

  /// [measure] must inventory the complete covered namespace while this
  /// transaction is held. All its writers must reserve before writing and
  /// retain their hold until every underlying write has settled. Counting an
  /// active writer twice is safe. Unknown measurement rejects admission.
  Future<String?> reserve({required int bytes, required int limitBytes,
      required Future<int?> Function() measure}) async {
    if (bytes <= 0 || limitBytes < 0 || bytes > limitBytes) return null;
    try {
      return await db.transaction((txn) async {
        final measured = await measure();
        if (measured == null || measured < 0 || measured > limitBytes) return null;
        final rows = await txn.rawQuery(
            'SELECT COALESCE(SUM(bytes), 0) AS reserved FROM optional_media_reservations');
        final reserved = rows.single['reserved'];
        if (reserved is! int || reserved < 0 || reserved > limitBytes - measured ||
            bytes > limitBytes - measured - reserved) return null;
        final random = Random.secure();
        final token = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
        await txn.insert('optional_media_reservations', {'token': token, 'bytes': bytes});
        return token;
      });
    } catch (_) {
      // A busy, full, corrupted or unavailable database never admits a write.
      return null;
    }
  }

  /// Only call after the underlying write and temporary-file handling have
  /// completely settled, including on failure. No automatic crash recovery.
  Future<bool> releaseSettled(String token) async {
    if (token.isEmpty) return false;
    try {
      return await db.transaction((txn) async =>
          await txn.delete('optional_media_reservations', where: 'token=?',
              whereArgs: [token]) == 1);
    } catch (_) {
      return false;
    }
  }
}
