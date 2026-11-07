import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

/// Identity of an attachment in the last confirmed local chat snapshot.
class SourceAttachmentIdentity {
  const SourceAttachmentIdentity(
      {required this.project,
      required this.uid,
      required this.sid,
      required this.chatId,
      required this.messageId,
      required this.fileId,
      required this.fileKey,
      required this.fileUrl});

  final String project, uid, sid, chatId, messageId, fileId, fileKey, fileUrl;
  bool get valid => [
        project,
        uid,
        sid,
        chatId,
        messageId,
        fileId,
        fileKey,
        fileUrl
      ].every((part) => part.isNotEmpty);
}

/// Checks the exact source in the same SQLite transaction as its caller's
/// database work. The callback must not expose bytes or perform irreversible
/// side effects: its SQL changes are rolled back if the source changes.
/// This confirms local provenance, not remote freshness.
class SourceAttachmentGuard {
  const SourceAttachmentGuard(this.db,
      {this.attachedSnapshot = false, this.attachedSnapshotPath});
  final Database db;

  /// When true the snapshot database must have been attached as
  /// `source_snapshot` to this exact guarded connection.
  final bool attachedSnapshot;
  final String? attachedSnapshotPath;
  String get _prefix => attachedSnapshot ? 'source_snapshot.' : '';

  Future<T?> run<T>(SourceAttachmentIdentity source, bool Function() current,
      Future<T> Function(Transaction txn, int sequence) action,
      {int? expectedSequence, String? expectedSnapshotHash}) async {
    if (!source.valid || !current()) return null;
    try {
      return await db.transaction((txn) async {
        final version = await _check(txn, source, current);
        if (version == null ||
            (expectedSequence != null && version.$1 != expectedSequence) ||
            (expectedSnapshotHash != null &&
                version.$2 != expectedSnapshotHash)) {
          throw const _SourceChanged();
        }
        final result = await action(txn, version.$1);
        final after = await _check(txn, source, current);
        if (after != version || !current()) throw const _SourceChanged();
        return result;
      });
    } on _SourceChanged {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<(int, String)?> capture(
          SourceAttachmentIdentity source, bool Function() current) =>
      run(source, current, (txn, seq) async {
        final rows = await txn.rawQuery(
            'SELECT payload FROM ${_prefix}chat_server_snapshot '
            'WHERE project=? AND uid=? AND sid=? AND chat=?',
            [source.project, source.uid, source.sid, source.chatId]);
        return (
          seq,
          sha256
              .convert(utf8.encode(rows.single['payload'] as String))
              .toString()
        );
      });

  Future<(int, String)?> _check(Transaction txn,
      SourceAttachmentIdentity source, bool Function() current) async {
    if (!current()) return null;
    if (attachedSnapshot) {
      final expected = attachedSnapshotPath;
      if (expected == null || expected.isEmpty) return null;
      final dbs = await txn.rawQuery('PRAGMA database_list');
      final matches =
          dbs.where((row) => row['name'] == 'source_snapshot').toList();
      if (matches.length != 1 || matches.single['file'] is! String) return null;
      final actual =
          await File(matches.single['file'] as String).resolveSymbolicLinks();
      final resolved = await File(expected).resolveSymbolicLinks();
      if (Platform.isWindows
          ? actual.toLowerCase() != resolved.toLowerCase()
          : actual != resolved) return null;
    }
    final args = [source.project, source.uid, source.sid, source.chatId];
    final logout = await txn.query('media_cache_logout_tombstones',
        columns: ['sid'],
        where: 'project=? AND uid=? AND sid=?',
        whereArgs: [source.project, source.uid, source.sid]);
    if (!current() || logout.isNotEmpty) return null;
    const where = 'project=? AND uid=? AND sid=? AND chat=?';
    final attempts = await txn.rawQuery(
        'SELECT seq, blocked FROM ${_prefix}chat_server_attempt '
        'WHERE $where',
        args);
    if (!current() ||
        attempts.length != 1 ||
        attempts.single['blocked'] != 0 ||
        attempts.single['seq'] is! int) return null;
    final rows = await txn.rawQuery(
        'SELECT payload FROM ${_prefix}chat_server_snapshot '
        'WHERE $where',
        args);
    if (!current() || rows.length != 1 || rows.single['payload'] is! String)
      return null;
    final raw = rows.single['payload'] as String;
    if (raw.length > 8 * 1024 * 1024) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! List) return null;
    final messages = decoded
        .whereType<Map>()
        .where((message) =>
            message['id'] == source.messageId &&
            message['chat_id'] == source.chatId)
        .toList();
    if (messages.length != 1) return null;
    final message = messages.single;
    if (source.messageId.startsWith('local_') ||
        message['client_id'] != null ||
        message['delivery_status'] != 'sent') return null;
    final attachments = message['attachments'];
    if (attachments is! List) return null;
    final withId = attachments
        .whereType<Map>()
        .where((file) => file['id'] == source.fileId)
        .toList();
    if (withId.length != 1) return null;
    final matches = withId
        .where((file) =>
            file['chat_id'] == source.chatId &&
            file['message_id'] == source.messageId &&
            file['file_key'] == source.fileKey &&
            file['file_url'] == source.fileUrl &&
            file['is_deleted'] == false &&
            file['deletion_verified'] == true)
        .toList();
    return matches.length == 1 && current()
        ? (
            attempts.single['seq'] as int,
            sha256.convert(utf8.encode(raw)).toString()
          )
        : null;
  }
}

class _SourceChanged implements Exception {
  const _SourceChanged();
}
