import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

/// Isolated QA logical-payload ledger. It neither measures disk nor deletes files.
/// Never use as a physical quota or against a production cache namespace.
class QaNewsPayloadLedger {
  QaNewsPayloadLedger(this.db, this.namespace, this.epoch);
  final Database db;
  final String namespace;
  final String epoch;

  static Future<void> createSchema(Database db) => db.execute(
      'CREATE TABLE IF NOT EXISTS qa_news_payload_ledger ('
      'namespace TEXT NOT NULL, epoch TEXT NOT NULL, token TEXT NOT NULL, '
      'bytes INTEGER NOT NULL CHECK(bytes > 0), '
      'state TEXT NOT NULL CHECK(state IN (\'held\',\'published\')), '
      'PRIMARY KEY(namespace, epoch, token))');

  Future<QaNewsPayloadTicket?> reserve(int bytes, int limit) async {
    if (namespace.isEmpty || epoch.isEmpty || bytes <= 0 || limit < bytes) return null;
    try {
      return await db.transaction((tx) async {
        final rows = await tx.rawQuery(
            'SELECT COALESCE(SUM(bytes),0) AS total FROM qa_news_payload_ledger '
            'WHERE namespace=?', [namespace]);
        final used = rows.single['total'];
        if (used is! int || used < 0 || used > limit - bytes) return null;
        final token = base64UrlEncode(List<int>.generate(
            32, (_) => Random.secure().nextInt(256)));
        await tx.insert('qa_news_payload_ledger', {
          'namespace': namespace, 'epoch': epoch, 'token': token,
          'bytes': bytes, 'state': 'held',
        });
        return QaNewsPayloadTicket._(namespace, epoch, token);
      });
    } catch (_) {
      return null;
    }
  }

  /// Call only after confirmed publication. An ambiguous result is never retried
  /// as a release: the held or published row continues to consume capacity.
  Future<bool> publish(QaNewsPayloadTicket ticket) => _transition(ticket, true);

  /// Caller must first prove no blob or other physical side effect exists.
  Future<bool> releaseUnwritten(QaNewsPayloadTicket ticket) => _transition(ticket, false);

  Future<bool> _transition(QaNewsPayloadTicket ticket, bool publish) async {
    if (ticket._namespace != namespace || ticket._epoch != epoch) return false;
    try {
      return await db.transaction((tx) async {
        const where = 'namespace=? AND epoch=? AND token=? AND state=?';
        final args = [namespace, epoch, ticket._token, 'held'];
        final changed = publish
            ? await tx.update('qa_news_payload_ledger', {'state': 'published'},
                where: where, whereArgs: args)
            : await tx.delete('qa_news_payload_ledger', where: where, whereArgs: args);
        return changed == 1;
      });
    } catch (_) {
      return false;
    }
  }
}

class QaNewsPayloadTicket {
  QaNewsPayloadTicket._(this._namespace, this._epoch, this._token);
  final String _namespace;
  final String _epoch;
  final String _token;
}
