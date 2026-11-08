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

  static const _holdsSchema = 'CREATE TABLE optional_media_reservations '
      '(token TEXT PRIMARY KEY NOT NULL, bytes INTEGER NOT NULL CHECK(bytes>0))';
  static const _revisionSchema = 'CREATE TABLE optional_media_revision '
      '(id INTEGER PRIMARY KEY CHECK(id=1), incarnation TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>=0))';

  /// Explicit QA initialisation. Never invent a revision for existing holds.
  static Future<void> createSchema(Database db) => db.transaction((tx) async {
    final rows = await tx.rawQuery("SELECT name,sql FROM sqlite_master WHERE name IN ('optional_media_reservations','optional_media_revision')");
    if (rows.isEmpty) {
      await tx.execute(_holdsSchema);
      await tx.execute(_revisionSchema);
      final id = base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
      await tx.insert('optional_media_revision', {'id': 1, 'incarnation': id, 'revision': 0});
    }
    if (await _revision(tx) == null) throw StateError('Invalid reservation schema');
  });

  static Future<(String, int)?> _revision(Transaction tx) async {
    final rows = await tx.rawQuery("SELECT name,sql FROM sqlite_master WHERE name IN ('optional_media_reservations','optional_media_revision')");
    if (rows.length != 2) return null;
    final schema = {for (final row in rows) row['name']: row['sql']};
    if (schema['optional_media_reservations'] != _holdsSchema || schema['optional_media_revision'] != _revisionSchema) return null;
    final extra = await tx.rawQuery("SELECT name FROM sqlite_master WHERE tbl_name IN ('optional_media_reservations','optional_media_revision') AND type IN ('trigger','index') AND name NOT GLOB 'sqlite_*'");
    if (extra.isNotEmpty) return null;
    final data = await tx.rawQuery('SELECT id,incarnation,revision,typeof(revision) AS rt FROM optional_media_revision');
    if (data.length != 1 || data.single['id'] != 1 || data.single['rt'] != 'integer') return null;
    final id = data.single['incarnation'], revision = data.single['revision'];
    if (id is! String || id.length != 44 || revision is! int || revision < 0) return null;
    try { if (base64Url.decode(id).length != 32) return null; }
    on FormatException { return null; }
    final invalid = await tx.rawQuery("SELECT 1 FROM optional_media_reservations WHERE typeof(token)<>'text' OR length(token)=0 OR typeof(bytes)<>'integer' OR bytes<=0 LIMIT 1");
    if (invalid.isNotEmpty) return null;
    return (id, revision);
  }

  /// Capture before scanning. A completed writer invalidates this observation.
  Future<OptionalMediaRevision?> captureRevision(String namespace) async {
    if (namespace.isEmpty) return null;
    try {
      return await db.transaction((tx) async {
        final value = await _revision(tx);
        return value == null || value.$2 == 9223372036854775807
            ? null : OptionalMediaRevision._(namespace, value.$1, value.$2);
      });
    } catch (_) { return null; }
  }

  /// Caller must use the same namespace and discard late or unknown scans.
  /// This protects cooperating writers only, not external writes or DB growth.
  Future<OptionalMediaHold?> reserveIfRevision({required String namespace,
      required OptionalMediaRevision observation, required int measuredBytes,
      required int bytes, required int limitBytes}) async {
    if (namespace.isEmpty || namespace != observation._namespace || bytes <= 0 ||
        limitBytes < 0 || measuredBytes < 0 || bytes > limitBytes) return null;
    try {
      return await db.transaction((tx) async {
        final value = await _revision(tx);
        if (value == null || value.$2 == 9223372036854775807 || value.$1 != observation._incarnation || value.$2 != observation._revision) return null;
        final token = await _insertIfFits(tx, measuredBytes, bytes, limitBytes);
        return token == null ? null : OptionalMediaHold._(namespace, value.$1, token);
      });
    } catch (_) { return null; }
  }

  static Future<String?> _insertIfFits(Transaction tx, int measured, int bytes, int limitBytes) async {
    if (measured > limitBytes) return null;
    final rows = await tx.rawQuery('SELECT COALESCE(SUM(bytes), 0) AS reserved FROM optional_media_reservations');
    final reserved = rows.single['reserved'];
    if (reserved is! int || reserved < 0 || reserved > limitBytes - measured || bytes > limitBytes - measured - reserved) return null;
    final token = base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    await tx.insert('optional_media_reservations', {'token': token, 'bytes': bytes});
    return token;
  }

  /// [measure] must inventory the complete covered namespace while this
  /// transaction is held. All its writers must reserve before writing and
  /// retain their hold until every underlying write has settled. Counting an
  /// active writer twice is safe. Unknown measurement rejects admission.
  Future<String?> reserve({required int bytes, required int limitBytes,
      required Future<int?> Function() measure}) async {
    if (bytes <= 0 || limitBytes < 0 || bytes > limitBytes) return null;
    try {
      return await db.transaction((txn) async {
        final current = await _revision(txn);
        if (current == null || current.$2 == 9223372036854775807) return null;
        final measured = await measure();
        if (measured == null || measured < 0 || measured > limitBytes) return null;
        return _insertIfFits(txn, measured, bytes, limitBytes);
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
      return await db.transaction((txn) async {
        final current = await _revision(txn);
        if (current == null || current.$2 == 9223372036854775807) return false;
        final removed = await txn.delete('optional_media_reservations', where: 'token=?', whereArgs: [token]);
        if (removed != 1) return false;
        final updated = await txn.update('optional_media_revision', {'revision': current.$2 + 1}, where: 'id=1 AND revision=? AND incarnation=?', whereArgs: [current.$2, current.$1]);
        if (updated != 1) throw StateError('Reservation revision changed');
        return true;
      });
    } catch (_) {
      return false;
    }
  }

  /// Only after the actual write and cleanup have settled. A hold created by a
  /// different database incarnation or namespace cannot release this one.
  Future<bool> releaseGuarded(OptionalMediaHold hold, String namespace) async {
    if (namespace != hold._namespace) return false;
    try {
      return await db.transaction((txn) async {
        final current = await _revision(txn);
        if (current == null || current.$1 != hold._incarnation || current.$2 == 9223372036854775807) return false;
        final removed = await txn.delete('optional_media_reservations', where: 'token=?', whereArgs: [hold._token]);
        if (removed != 1) return false;
        final updated = await txn.update('optional_media_revision', {'revision': current.$2 + 1}, where: 'id=1 AND revision=? AND incarnation=?', whereArgs: [current.$2, current.$1]);
        if (updated != 1) throw StateError('Reservation revision changed');
        return true;
      });
    } catch (_) { return false; }
  }
}

class OptionalMediaRevision {
  OptionalMediaRevision._(this._namespace, this._incarnation, this._revision);
  final String _namespace, _incarnation;
  final int _revision;
}

class OptionalMediaHold {
  OptionalMediaHold._(this._namespace, this._incarnation, this._token);
  final String _namespace, _incarnation, _token;
}
