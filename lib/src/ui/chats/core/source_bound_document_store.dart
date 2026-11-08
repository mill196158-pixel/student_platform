import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_authorizer.dart';

/// A bounded private copy committed atomically with its SHA and source tuple.
/// It represents the last locally confirmed snapshot, not remote freshness.
class SourceBoundDocumentStore {
  const SourceBoundDocumentStore(this.guard, this.fence);
  final SourceAttachmentGuard guard;
  final PinnedAccessFence fence;
  static const int maxFileBytes = 8 * 1024 * 1024;
  static const int maxScopeBytes = 64 * 1024 * 1024;

  Future<void> _ensure() async {
    await guard.db.execute('CREATE TABLE IF NOT EXISTS source_bound_documents ('
        'project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, '
        'chat TEXT NOT NULL, message TEXT NOT NULL, file TEXT NOT NULL, key TEXT NOT NULL, '
        'url TEXT NOT NULL, sha TEXT NOT NULL, bytes BLOB NOT NULL, '
        'PRIMARY KEY(project,uid,sid,chat,message,file))');
    await guard.db.execute('CREATE TABLE IF NOT EXISTS source_bound_proofs ('
        'project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL, '
        'chat TEXT NOT NULL, message TEXT NOT NULL, file TEXT NOT NULL, '
        'revision INTEGER NOT NULL, sha TEXT NOT NULL, '
        'PRIMARY KEY(project,uid,sid,chat,message,file))');
  }

  List<String> _args(SourceAttachmentIdentity s) =>
      [s.project, s.uid, s.sid, s.chatId, s.messageId, s.fileId];
  static const _where =
      'project=? AND uid=? AND sid=? AND chat=? AND message=? AND file=?';

  String _fenceId(SourceAttachmentIdentity source) => sha256
      .convert(
          utf8.encode(jsonEncode([source.project, source.uid, source.fileKey])))
      .toString();

  /// The caller must download using this grant's signed URL. The fence remains
  /// pending until the copy and its checksum are committed.
  Future<bool> publish(SourceAttachmentIdentity source, bool Function() current,
      SourceAccessGrant grant, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxFileBytes || !current()) {
      await grant.close();
      return false;
    }
    final stableBytes = Uint8List.fromList(bytes);
    try {
      await _ensure();
      final digest = sha256.convert(stableBytes).toString();
      bool canPublish() => current() && grant.isOpen;
      final stored = await guard.run(source, canPublish, (txn, _) async {
        if (!identical(guard.db, fence.db) ||
            !await grant.validInTransaction(txn, source, fence)) {
          throw StateError('Authorization changed');
        }
        final totals = await txn.rawQuery(
            'SELECT COALESCE(SUM(length(bytes)),0) AS size '
            'FROM source_bound_documents WHERE project=? AND uid=? AND sid=? '
            'AND NOT (chat=? AND message=? AND file=?)',
            _args(source));
        final total = totals.single['size'];
        if (total is! int ||
            total + stableBytes.length > maxScopeBytes ||
            !current()) {
          throw StateError('Document quota or scope changed');
        }
        await txn.insert(
            'source_bound_documents',
            {
              'project': source.project,
              'uid': source.uid,
              'sid': source.sid,
              'chat': source.chatId,
              'message': source.messageId,
              'file': source.fileId,
              'key': source.fileKey,
              'url': source.fileUrl,
              'sha': digest,
              'bytes': stableBytes
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        if (!current() || !await grant.validInTransaction(txn, source, fence))
          throw StateError('Session changed');
        await fence.markPinned(
            txn, source.project, source.uid, source.fileKey, digest);
        final state = await txn.query('pinned_fence_state',
            columns: ['revision'],
            where: 'id=?',
            whereArgs: [_fenceId(source)]);
        if (state.length != 1 ||
            state.single['revision'] is! int ||
            !current()) {
          throw StateError('Fence revision unavailable');
        }
        await txn.insert(
            'source_bound_proofs',
            {
              'project': source.project,
              'uid': source.uid,
              'sid': source.sid,
              'chat': source.chatId,
              'message': source.messageId,
              'file': source.fileId,
              'revision': state.single['revision'],
              'sha': digest,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        if (!current()) throw StateError('Session changed');
        return true;
      },
          expectedSequence: grant.sequence,
          expectedSnapshotHash: grant.snapshotHash);
      if (stored != true || !current()) return false;
      await grant.close(published: true);
      return await fence.canRead(source.project, source.uid, source.fileKey,
              checksum: digest) &&
          current();
    } catch (_) {
      return false;
    } finally {
      await grant.close();
    }
  }

  /// Verifies source, durable fence, owner and bytes in one DB transaction.
  Future<Uint8List?> read(
      SourceAttachmentIdentity source, bool Function() current) async {
    try {
      await _ensure();
      return await guard.run<Uint8List?>(source, current, (txn, _) async {
        final rows = await txn.query('source_bound_documents',
            where: _where, whereArgs: _args(source));
        if (rows.length != 1 ||
            rows.single['key'] != source.fileKey ||
            rows.single['url'] != source.fileUrl ||
            rows.single['sha'] is! String ||
            rows.single['bytes'] is! Uint8List ||
            !current()) return null;
        final bytes = rows.single['bytes'] as Uint8List;
        final digest = sha256.convert(bytes).toString();
        final proofs = await txn.query('source_bound_proofs',
            where: _where, whereArgs: _args(source));
        final state = await txn.query('pinned_fence_state',
            columns: ['revision'],
            where: 'id=?',
            whereArgs: [_fenceId(source)]);
        if (bytes.isEmpty ||
            bytes.length > maxFileBytes ||
            rows.single['sha'] != digest ||
            proofs.length != 1 ||
            proofs.single['sha'] != digest ||
            state.length != 1 ||
            state.single['revision'] is! int ||
            proofs.single['revision'] != state.single['revision'] ||
            !await fence.canReadInTransaction(
                txn, source.project, source.uid, source.fileKey,
                checksum: digest) ||
            !current()) return null;
        return bytes;
      });
    } catch (_) {
      return null;
    }
  }
}
