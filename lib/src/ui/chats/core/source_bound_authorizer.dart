import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';

/// Response from a single independent server request. No legacy cache grant
/// or signed URL lease is created by this adapter.
class SourceAccessResponse {
  const SourceAccessResponse.allow(
      {required this.fileId, required this.key, required this.signedUrl})
      : denied = false;
  const SourceAccessResponse.deny()
      : denied = true,
        fileId = '',
        key = '',
        signedUrl = '';
  final bool denied;
  final String fileId, key, signedUrl;
}

/// Owns a durable fence until publication completes or the operation is closed.
class SourceAccessGrant {
  SourceAccessGrant._(this.signedUrl, this.sequence, this.snapshotHash,
      this._source, this._fence, this._token, this._current);
  final Uri signedUrl;
  final int sequence;
  final String snapshotHash;
  final SourceAttachmentIdentity _source;
  final PinnedAccessFence _fence;
  final String _token;
  final bool Function() _current;
  bool _closed = false;
  bool get isOpen => !_closed && _current();

  Future<bool> validInTransaction(Transaction txn,
      SourceAttachmentIdentity source, PinnedAccessFence fence) async {
    if (_closed ||
        !_current() ||
        !identical(fence.db, _fence.db) ||
        source.project != _source.project ||
        source.uid != _source.uid ||
        source.sid != _source.sid ||
        source.chatId != _source.chatId ||
        source.messageId != _source.messageId ||
        source.fileId != _source.fileId ||
        source.fileKey != _source.fileKey ||
        source.fileUrl != _source.fileUrl) return false;
    final id = sha256
        .convert(utf8
            .encode(jsonEncode([source.project, source.uid, source.fileKey])))
        .toString();
    final rows = await txn.rawQuery(
        'SELECT p.revision AS pending_revision, s.revision AS state_revision '
        'FROM pinned_fence_pending p JOIN pinned_fence_state s ON s.id=p.id '
        'WHERE p.token=? AND p.id=?',
        [_token, id]);
    return !_closed &&
        _current() &&
        rows.length == 1 &&
        rows.single['pending_revision'] == rows.single['state_revision'];
  }

  /// Only call with [published] after proof and bytes are committed together.
  Future<void> close({bool published = false}) async {
    if (_closed) return;
    _closed = true;
    await _fence.finish(_token, allowed: published && _current() ? true : null);
  }
}

class SourceBoundAuthorizer {
  const SourceBoundAuthorizer(
      {required this.guard,
      required this.fence,
      required this.storageHost,
      required this.keyForUrl});
  final SourceAttachmentGuard guard;
  final PinnedAccessFence fence;
  final String storageHost;
  final String? Function(String url) keyForUrl;

  Future<SourceAccessGrant?> authorize(SourceAttachmentIdentity source,
      bool Function() current, Future<SourceAccessResponse> Function() request,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final sourceUri = Uri.tryParse(source.fileUrl);
    if (sourceUri == null ||
        sourceUri.scheme != 'https' ||
        sourceUri.host != storageHost ||
        keyForUrl(source.fileUrl) != source.fileKey) return null;
    final version = await guard.capture(source, current);
    if (version == null || !current()) return null;
    final (seq, snapshotHash) = version;
    final token = await fence.begin(source.project, source.uid, source.fileKey);
    var handedOff = false;
    var abandoned = false;
    var denialSeen = false;
    try {
      if (!current() ||
          await guard.run(source, current, (_, __) async => true,
                  expectedSequence: seq, expectedSnapshotHash: snapshotHash) !=
              true) return null;
      Future<SourceAccessGrant?> perform() async {
        try {
          final response = await request();
          if (response.denied) {
            denialSeen = true;
            await fence.finish(token, allowed: false);
            return null;
          }
          final uri = Uri.tryParse(response.signedUrl);
          if (abandoned ||
              !current() ||
              response.fileId != source.fileId ||
              response.key != source.fileKey ||
              uri == null ||
              uri.scheme != 'https' ||
              uri.host != storageHost ||
              keyForUrl(uri.toString()) != source.fileKey ||
              await guard.run(source, current, (_, __) async => true,
                      expectedSequence: seq,
                      expectedSnapshotHash: snapshotHash) !=
                  true ||
              abandoned ||
              !current()) {
            await fence.finish(token, allowed: null);
            return null;
          }
          handedOff = true;
          return SourceAccessGrant._(
              uri, seq, snapshotHash, source, fence, token, current);
        } catch (_) {
          if (!denialSeen) await fence.finish(token, allowed: null);
          return null;
        }
      }

      return await perform().timeout(timeout, onTimeout: () {
        abandoned = true;
        return null;
      });
    } finally {
      // Pending network requests retain the fence until their late result is
      // observed. A process crash is handled by durable fence recovery.
      if (!handedOff && !abandoned && !denialSeen)
        await fence.finish(token, allowed: null);
    }
  }
}
