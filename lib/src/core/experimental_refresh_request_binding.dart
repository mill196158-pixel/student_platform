import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/core/durable_active_session_registry.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';

/// An in-memory request/credential epoch for a single guarded engine. It is
/// an experimental admission primitive, not a complete refresh boundary.
class ExperimentalRefreshRequestBinding {
  ExperimentalRefreshRequestBinding._(this.registry, this.owner, this.snapshot,
      this._digest, this.currentRefreshToken);
  final DurableActiveSessionRegistry registry;
  final ProjectDatabaseOwnerCapability owner;
  final ActiveSessionSnapshot snapshot;
  final Digest _digest;
  final String? Function() currentRefreshToken;

  static Future<ExperimentalRefreshRequestBinding?> capture(
      DurableActiveSessionRegistry registry,
      ProjectDatabaseOwnerCapability owner,
      {required String uid,
      required String sid,
      required String? Function() currentRefreshToken}) async {
    try {
      final token = currentRefreshToken();
      final snapshot = await registry.read();
      if (token == null ||
          token.isEmpty ||
          snapshot == null ||
          snapshot.uid != uid ||
          snapshot.sid != sid ||
          !owner.isCurrentFor(registry.db)) return null;
      final valid = await registry.db.transaction((txn) =>
          registry.permitsHandoffInTransaction(txn, snapshot,
              uid: uid, sid: sid, owner: owner));
      if (!valid ||
          !owner.isCurrentFor(registry.db) ||
          currentRefreshToken() != token) return null;
      return ExperimentalRefreshRequestBinding._(registry, owner, snapshot,
          sha256.convert(utf8.encode(token)), currentRefreshToken);
    } catch (_) {
      return null;
    }
  }

  /// Reject uninspectable bodies, mismatched credential or a stale epoch
  /// before any network work. Never logs or persists the refresh token.
  Future<bool> permits(http.BaseRequest request) async {
    try {
      final uri = request.url;
      if (request is! http.Request ||
          request.method != 'POST' ||
          uri.origin != Uri.parse(registry.project).origin ||
          uri.userInfo.isNotEmpty ||
          uri.path != '/auth/v1/token' ||
          uri.queryParameters['grant_type'] != 'refresh_token') return false;
      final body = jsonDecode(request.body);
      if (body is! Map || body['refresh_token'] is! String) return false;
      final token = currentRefreshToken();
      if (token == null ||
          token != body['refresh_token'] ||
          sha256.convert(utf8.encode(token)) != _digest ||
          !owner.isCurrentFor(registry.db)) return false;
      final valid = await registry.db.transaction((txn) =>
          registry.permitsHandoffInTransaction(txn, snapshot,
              uid: snapshot.uid!, sid: snapshot.sid!, owner: owner));
      return valid &&
          owner.isCurrentFor(registry.db) &&
          currentRefreshToken() == token;
    } catch (_) {
      return false;
    }
  }
}
