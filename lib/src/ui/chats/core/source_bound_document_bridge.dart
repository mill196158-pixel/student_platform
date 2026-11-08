import 'dart:typed_data';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/core/source_attachment_guard.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_authorizer.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_document_network.dart';
import 'package:student_platform/src/ui/chats/core/source_bound_document_store.dart';
import 'package:student_platform/src/ui/chats/core/source_snapshot_attachment.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Only confirmed DOCX message attachments participate in the first stage.
bool supportsSourceBoundDocument(ChatFile file) {
  final name = file.fileName.toLowerCase();
  final mime = file.fileType.toLowerCase();
  final uri = Uri.tryParse(file.fileUrl);
  final key = ChatFileAccess.keyFor(file.fileUrl);
  return (name.endsWith('.docx') ||
          mime == 'application/vnd.openxmlformats-officedocument.wordprocessingml.document') &&
      !file.isDeleted && file.deletionVerified && file.chatId.isNotEmpty &&
      file.id.isNotEmpty && file.messageId != null && file.messageId!.isNotEmpty &&
      uri?.scheme == 'https' && key != null && key == file.fileKey;
}

/// A scoped bridge for a confirmed attachment. This does not materialize or
/// export files; consumers must use [read] in both online and cache-only UI.
class SourceBoundDocumentBridge {
  SourceBoundDocumentBridge._(
      this.source, this._current, this._online, this._store, this._network);
  final SourceAttachmentIdentity source;
  final bool Function() _current, _online;
  final SourceBoundDocumentStore _store;
  final SourceBoundDocumentNetwork _network;

  static Future<SourceBoundDocumentBridge?> open({
    required ChatFile file,
    required MediaCacheProtection protection,
    required ProjectChatServerCache chatCache,
    required SupabaseClient client,
    required bool Function() ownerCurrent,
    required bool Function() online,
  }) async {
    try {
      final session = client.auth.currentSession;
      final owner = chatCache.scope.capture();
      final binding = chatCache.currentBinding();
      final uid = session?.user.id, sid = binding?.sessionId;
      final key = ChatFileAccess.keyFor(file.fileUrl);
      final uri = Uri.tryParse(file.fileUrl);
      if (!supportsSourceBoundDocument(file) || session == null ||
          owner == null ||
          !chatCache.scope.matchesSession(owner, session) ||
          uid == null ||
          uid.isEmpty ||
          sid == null ||
          sid.isEmpty ||
          binding?.userId != uid ||
          binding?.issuer != '${chatCache.project}/auth/v1' ||
          protection.project != chatCache.project ||
          protection.currentOwner() != uid ||
          protection.currentSessionId?.call() != sid ||
          file.isDeleted ||
          !file.deletionVerified ||
          uri?.scheme != 'https' ||
          key == null ||
          key != file.fileKey ||
          file.messageId == null ||
          file.messageId!.isEmpty ||
          !ownerCurrent()) return null;
      final accessToken = session.accessToken;
      bool current() {
        try {
          final latest = chatCache.currentBinding();
          return ownerCurrent() &&
              chatCache.scope.isCurrent(owner) &&
              chatCache.scope
                  .matchesSession(owner, client.auth.currentSession) &&
              protection.db.isOpen &&
              chatCache.db.isOpen &&
              client.auth.currentSession?.accessToken == accessToken &&
              client.auth.currentSession?.user.id == uid &&
              protection.currentOwner() == uid &&
              protection.currentSessionId?.call() == sid &&
              latest?.userId == uid &&
              latest?.sessionId == sid &&
              latest?.issuer == binding!.issuer;
        } catch (_) {
          return false;
        }
      }

      final path = await attachSourceSnapshot(protection.db, chatCache.db);
      if (path == null || !current()) return null;
      final source = SourceAttachmentIdentity(
          project: chatCache.project,
          uid: uid,
          sid: sid,
          chatId: file.chatId,
          messageId: file.messageId!,
          fileId: file.id,
          fileKey: key,
          fileUrl: file.fileUrl);
      if (!source.valid) return null;
      final guard = SourceAttachmentGuard(protection.db,
          attachedSnapshot: true, attachedSnapshotPath: path);
      final fence = PinnedAccessFence(protection.db,
          databaseToken: protection.databaseToken);
      final store = SourceBoundDocumentStore(guard, fence);
      final authorizer = SourceBoundAuthorizer(
          guard: guard,
          fence: fence,
          storageHost: ChatFileAccess.storageHost,
          keyForUrl: ChatFileAccess.keyFor);
      return SourceBoundDocumentBridge._(source, current, online, store,
          SourceBoundDocumentNetwork(client, authorizer, store));
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> read() => _store.read(source, _current);

  Future<File?> export(String name) async {
    final bytes = await read();
    if (bytes == null || !_current()) return null;
    final digest = sha256.convert(bytes);
    return ChatFileAccess.exportVerifiedSource(
        url: source.fileUrl,
        fileName: name,
        bytes: bytes,
        stillVerified: () async {
          final latest = await read();
          return latest != null &&
              _current() &&
              sha256.convert(latest) == digest;
        });
  }

  Future<SourceDispatch<T>?> dispatch<T>(
          File exported, Future<T> Function(String path) operation) =>
      _store.dispatch<T>(source, _current, exported, operation);

  /// Never dispatches a network request from cache-only mode; the online
  /// permit is rechecked across every await in the network operation.
  Future<bool> refresh() async {
    bool allowed() {
      try {
        return _current() && _online();
      } catch (_) {
        return false;
      }
    }

    if (!allowed()) return false;
    return _network.download(source, allowed);
  }
}
