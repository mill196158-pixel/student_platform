import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

/// Isolated QA logical-payload ledger, never a physical quota. A complete DB
/// clone or rollback requires an external authority and is not detected here.
class QaNewsPayloadLedger {
  QaNewsPayloadLedger._(this.db, this.namespace, this.epoch, this._incarnation);
  final Database db;
  final String namespace;
  final String epoch;
  final String _incarnation;
  static const _meta = 'CREATE TABLE qa_ledger_meta (id INTEGER PRIMARY KEY CHECK(id=1), protocol INTEGER NOT NULL CHECK(protocol=1), incarnation TEXT NOT NULL)';
  static const _entries = 'CREATE TABLE qa_news_payload_ledger (namespace TEXT NOT NULL, epoch TEXT NOT NULL, token TEXT NOT NULL, bytes INTEGER NOT NULL CHECK(bytes > 0), state TEXT NOT NULL CHECK(state IN (\'held\',\'published\')), PRIMARY KEY(namespace, epoch, token))';

  /// Only for a new dedicated, empty QA database. Never repairs an existing DB.
  static Future<QaNewsPayloadLedger?> create(Database db, String namespace, String epoch) async {
    if (namespace.isEmpty || epoch.isEmpty) return null;
    try {
      return await db.transaction((tx) async {
        final tables = await tx.rawQuery("SELECT name FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'");
        if (tables.isNotEmpty) return null;
        await tx.execute(_meta);
        await tx.execute(_entries);
        final id = base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
        await tx.insert('qa_ledger_meta', {'id': 1, 'protocol': 1, 'incarnation': id});
        if (await _validate(tx) != id) throw StateError('Invalid QA ledger');
        return QaNewsPayloadLedger._(db, namespace, epoch, id);
      });
    } catch (_) { return null; }
  }

  /// Read-only admission: missing, incomplete, or mismatched state is rejected.
  static Future<QaNewsPayloadLedger?> openExisting(Database db, String namespace, String epoch) async {
    if (namespace.isEmpty || epoch.isEmpty) return null;
    try {
      return await db.transaction((tx) async {
        final id = await _validate(tx);
        return id == null ? null : QaNewsPayloadLedger._(db, namespace, epoch, id);
      });
    } catch (_) { return null; }
  }

  static Future<String?> _validate(Transaction tx) async {
    final schema = await tx.rawQuery("SELECT name,sql FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'");
    if (schema.length != 2) return null;
    final actual = {for (final row in schema) row['name']: row['sql']};
    if (actual['qa_ledger_meta'] != _meta || actual['qa_news_payload_ledger'] != _entries) return null;
    final meta = await tx.rawQuery("SELECT id,protocol,incarnation, typeof(id) AS id_type, typeof(protocol) AS protocol_type, typeof(incarnation) AS incarnation_type FROM qa_ledger_meta");
    if (meta.length != 1 || meta.single['id'] != 1 || meta.single['protocol'] != 1 || meta.single['id_type'] != 'integer' || meta.single['protocol_type'] != 'integer' || meta.single['incarnation_type'] != 'text') return null;
    final id = meta.single['incarnation'];
    if (id is! String || id.length != 44) return null;
    try {
      if (base64Url.decode(id).length != 32) return null;
    } on FormatException { return null; }
    final bad = await tx.rawQuery("SELECT 1 FROM qa_news_payload_ledger WHERE typeof(namespace)<>'text' OR length(namespace)=0 OR typeof(epoch)<>'text' OR length(epoch)=0 OR typeof(token)<>'text' OR length(token)=0 OR typeof(bytes)<>'integer' OR bytes<=0 OR typeof(state)<>'text' OR state NOT IN ('held','published') LIMIT 1");
    return bad.isEmpty ? id : null;
  }

  Future<QaNewsPayloadTicket?> reserve(int bytes, int limit) async {
    if (bytes <= 0 || limit < bytes) return null;
    try {
      return await db.transaction((tx) async {
        if (await _validate(tx) != _incarnation) return null;
        final rows = await tx.rawQuery('SELECT COALESCE(SUM(bytes),0) AS total FROM qa_news_payload_ledger WHERE namespace=?', [namespace]);
        final used = rows.single['total'];
        if (used is! int || used < 0 || used > limit - bytes) return null;
        final token = base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
        await tx.insert('qa_news_payload_ledger', {'namespace': namespace, 'epoch': epoch, 'token': token, 'bytes': bytes, 'state': 'held'});
        return QaNewsPayloadTicket._(namespace, epoch, token, _incarnation);
      });
    } catch (_) { return null; }
  }

  Future<bool> publish(QaNewsPayloadTicket ticket) => _transition(ticket, true);
  /// Caller must prove no physical side effect exists; not yet wired to a writer.
  Future<bool> releaseUnwritten(QaNewsPayloadTicket ticket) => _transition(ticket, false);
  Future<bool> _transition(QaNewsPayloadTicket ticket, bool publish) async {
    if (ticket._namespace != namespace || ticket._epoch != epoch || ticket._incarnation != _incarnation) return false;
    try {
      return await db.transaction((tx) async {
        if (await _validate(tx) != _incarnation) return false;
        const where = 'namespace=? AND epoch=? AND token=? AND state=?';
        final args = [namespace, epoch, ticket._token, 'held'];
        final changed = publish ? await tx.update('qa_news_payload_ledger', {'state': 'published'}, where: where, whereArgs: args) : await tx.delete('qa_news_payload_ledger', where: where, whereArgs: args);
        return changed == 1;
      });
    } catch (_) { return false; }
  }
}

class QaNewsPayloadTicket {
  QaNewsPayloadTicket._(this._namespace, this._epoch, this._token, this._incarnation);
  final String _namespace, _epoch, _token, _incarnation;
}
