import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../../../../core/session_capabilities.dart';
import '../../../../../core/offline_policy_grant.dart';
import '../../../../chats/core/project_chat_server_cache.dart';
import '../../../models/message.dart';
import '../models/chat_card_envelope.dart';
import 'chat_action_cards_cache.dart';

typedef ChatCardIdentity = (String messageId, String kind, String entityId);

ChatCardIdentity? chatActionCardIdentity(Message message) {
  if (!ChatCardEnvelope.isValidUuid(message.id) ||
      !ChatCardEnvelope.isValidUuid(message.cardEntityId)) return null;
  final kind = ChatActionCardsCache.canonicalKind(message.cardKind ?? '');
  if (kind != ChatActionCardKind.topicSelection &&
      kind != ChatActionCardKind.groupCollection) return null;
  return (message.id, kind, message.cardEntityId!);
}

/// A read-only preview of a batch response bound to the exact chat, message
/// and original session. A legacy or unverified card is never reused here.
class SavedChatCardPreviews {
  SavedChatCardPreviews(this.cache);

  final ProjectChatServerCache cache;
  static const _table = 'chat_action_card_preview_v1';
  static const _where = 'project=? AND uid=? AND sid=? AND chat=?';
  static const _chatLimit = 200;
  static const _ownerLimit = 400;
  static const _maxPayloadBytes = 8 * 1024;

  bool _same(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a?.issuer == b.issuer &&
      a?.userId == b.userId &&
      a?.sessionId == b.sessionId &&
      a?.notBefore == b.notBefore &&
      a?.expiresAt == b.expiresAt;

  Future<void> _create(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS $_table (
      project TEXT NOT NULL, uid TEXT NOT NULL, sid TEXT NOT NULL,
      chat TEXT NOT NULL, msg TEXT NOT NULL, kind TEXT NOT NULL,
      entity TEXT NOT NULL, payload TEXT NOT NULL,
      updated_ms INTEGER NOT NULL,
      PRIMARY KEY(project,uid,sid,chat,msg,kind,entity)
    )
  ''');

  Future<void> record(
      String chat, Map<ChatCardIdentity, ChatActionCardEntry?> rows,
      {required bool Function() isCurrent}) async {
    final owner = cache.scope.capture();
    final binding = cache.currentBinding();
    if (owner == null ||
        binding == null ||
        binding.userId != owner.userId ||
        !_same(cache.scope.bindingFor(owner, '${cache.project}/auth/v1'),
            binding) ||
        rows.isEmpty ||
        !isCurrent()) return;

    bool current() =>
        cache.scope.isCurrent(owner) &&
        _same(cache.currentBinding(), binding) &&
        isCurrent();
    try {
      await cache.db.transaction((txn) async {
        if (!current()) return;
        await _create(txn);
        final args = [cache.project, binding.userId, binding.sessionId, chat];
        for (final MapEntry(key: key, value: entry) in rows.entries) {
          final (msg, kind, entity) = key;
          final valid = entry != null &&
              entry.available &&
              !entry.tombstoned &&
              entry.status != 'unavailable' &&
              (entry.cardMessageId, entry.kind, entry.entityId) == key;
          // Keep the visible summary only. Mutations and organizer data
          // always require a current online response.
          final payload = valid
              ? jsonEncode({
                  'kind': kind,
                  'entity_id': entity,
                  'card_message_id': msg,
                  'available': true,
                  'status': entry.status,
                  'title': entry.title,
                  'description': entry.description,
                  'purpose': entry.purpose,
                  'compact_completed': entry.compactCompleted,
                })
              : null;
          if (payload == null ||
              utf8.encode(payload).length > _maxPayloadBytes) {
            await txn.delete(_table,
                where: '$_where AND msg=? AND kind=? AND entity=?',
                whereArgs: [...args, msg, kind, entity]);
            continue;
          }
          await txn.insert(
              _table,
              {
                'project': cache.project,
                'uid': binding.userId,
                'sid': binding.sessionId,
                'chat': chat,
                'msg': msg,
                'kind': kind,
                'entity': entity,
                'payload': payload,
                'updated_ms': DateTime.now().millisecondsSinceEpoch,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await txn.rawDelete('''
          DELETE FROM $_table WHERE $_where AND rowid NOT IN (
            SELECT rowid FROM $_table WHERE $_where
            ORDER BY updated_ms DESC, rowid DESC LIMIT ?
          )
        ''', [...args, ...args, _chatLimit]);
        // Old sessions and chats must not accumulate indefinitely when the
        // chat snapshot or account has since been replaced.
        final ownerArgs = [cache.project, binding.userId];
        await txn.rawDelete('''
          DELETE FROM $_table WHERE project=? AND uid=? AND rowid NOT IN (
            SELECT rowid FROM $_table WHERE project=? AND uid=?
            ORDER BY updated_ms DESC, rowid DESC LIMIT ?
          )
        ''', [...ownerArgs, ...ownerArgs, _ownerLimit]);
        if (!current()) throw const _StaleCardPreview();
      });
    } catch (_) {
      // A preview cache failure must not block the chat or its online cards.
    }
  }

  Future<Map<ChatCardIdentity, ChatActionCardEntry>> read(String chat,
      List<Message> messages, SessionCapabilities capabilities) async {
    final wanted = <ChatCardIdentity>{};
    for (final message in messages) {
      if (message.chatId != chat) continue;
      final identity = chatActionCardIdentity(message);
      if (identity != null) wanted.add(identity);
    }
    if (wanted.isEmpty) return const {};
    final permit = capabilities.capture(SessionCapability.cachedRead);
    final owner = cache.scope.capture();
    final binding = cache.currentBinding();
    if (permit == null ||
        owner == null ||
        binding == null ||
        binding.userId != owner.userId ||
        !_same(
            cache.scope.bindingFor(owner, '${cache.project}/auth/v1'), binding))
      return const {};

    bool current() =>
        capabilities.mode == SessionCapabilityMode.cacheOnly &&
        capabilities.owns(permit, owner) &&
        _same(cache.currentBinding(), binding);
    if (!current()) return const {};
    try {
      final rows = await cache.db.query(_table,
          where: _where,
          limit: _chatLimit,
          whereArgs: [cache.project, binding.userId, binding.sessionId, chat]);
      if (!current()) return const {};
      final result = <ChatCardIdentity, ChatActionCardEntry>{};
      for (final row in rows) {
        if (row['msg'] is! String ||
            row['kind'] is! String ||
            row['entity'] is! String ||
            row['payload'] is! String) continue;
        final key = (
          row['msg'] as String,
          row['kind'] as String,
          row['entity'] as String
        );
        if (!wanted.contains(key)) continue;
        final payload = row['payload'] as String;
        if (utf8.encode(payload).length > _maxPayloadBytes) continue;
        try {
          final data = jsonDecode(payload);
          if (data is! Map<String, dynamic>) continue;
          final entry = ChatActionCardEntry.fromCacheJson(data);
          if (entry != null &&
              entry.available &&
              !entry.tombstoned &&
              key == (entry.cardMessageId, entry.kind, entry.entityId)) {
            result[key] = entry;
          }
        } on FormatException {
          // A damaged preview must not hide other saved cards in this chat.
        }
      }
      return current() ? result : const {};
    } catch (_) {
      return const {};
    }
  }
}

/// An account switch during a write rolls back the entire projection.
class _StaleCardPreview implements Exception {
  const _StaleCardPreview();
}
