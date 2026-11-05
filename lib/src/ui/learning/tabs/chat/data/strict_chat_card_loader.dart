import 'dart:async';

import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_action_cards_cache.dart';

/// Loads only projections bound to the exact account, chat and message.
/// Old unscoped card snapshots are intentionally not used here.
class StrictChatCardLoader {
  StrictChatCardLoader({SupabaseClient? client, this.timeout = const Duration(seconds: 12)}) : _client = client;
  static StrictChatCardLoader instance = StrictChatCardLoader();
  final SupabaseClient? _client;
  final Duration timeout;
  final _queues = <(AuthSessionScope, AuthOperationScope, String), List<_CardRequest>>{};

  Future<ChatActionCardEntry> load({
    required AuthSessionScope? scope,
    required String chatId,
    required String messageId,
    required String kind,
    required String entityId,
  }) {
    final owner = scope?.capture();
    if (scope == null || owner == null || chatId.isEmpty ||
        messageId.isEmpty || entityId.isEmpty) {
      return Future.error(StateError('Карточку не удалось проверить'));
    }
    final request = _CardRequest(owner, messageId,
        ChatActionCardsCache.canonicalKind(kind), entityId);
    final key = (scope, owner, chatId);
    final queue = _queues.putIfAbsent(key, () {
      scheduleMicrotask(() => _flush(key));
      return [];
    });
    queue.add(request);
    return request.completer.future;
  }

  Future<void> _flush((AuthSessionScope, AuthOperationScope, String) key) async {
    final requests = _queues.remove(key) ?? [];
    if (requests.isEmpty) return;
    final scope = key.$1;
    try {
      if (requests.any((item) => !scope.isCurrent(item.owner))) {
        throw StateError('Сессия изменилась');
      }
      final client = _client ?? Supabase.instance.client;
      final response = <Object?>[];
      final unique = <(String, String, String), _CardRequest>{};
      for (final request in requests) {
        unique[(request.kind, request.entityId, request.messageId)] = request;
      }
      final items = unique.values.toList();
      for (var offset = 0; offset < items.length; offset += 50) {
        if (requests.any((item) => !scope.isCurrent(item.owner))) {
          throw StateError('Сессия изменилась');
        }
        final batch = items.skip(offset).take(50);
        final rows = await client.rpc('get_chat_action_cards_batch', params: {
          'p_chat_id': key.$3,
          'p_items': [for (final r in batch) {
            'kind': r.kind, 'entity_id': r.entityId, 'card_message_id': r.messageId,
          }],
        }).timeout(timeout);
        if (rows is! List) throw const FormatException('Invalid cards');
        response.addAll(rows);
      }
      for (final request in requests) {
        if (!scope.isCurrent(request.owner)) {
          request.completer.completeError(StateError('Сессия изменилась'));
          continue;
        }
        final matches = response.whereType<Map>().where((row) =>
            ChatActionCardsCache.canonicalKind('${row['kind'] ?? ''}') == request.kind &&
            row['entity_id'] == request.entityId &&
            row['card_message_id'] == request.messageId && row['available'] is bool &&
            row['status'] is String && (row['status'] as String).isNotEmpty).toList();
        if (matches.length != 1) {
          request.completer.completeError(const FormatException('Invalid card'));
          continue;
        }
        final entry = ChatActionCardEntry.fromBatchJson(Map<String, dynamic>.from(matches.single));
        if (entry == null) {
          request.completer.completeError(const FormatException('Invalid card'));
        } else {
          request.completer.complete(entry);
        }
      }
    } catch (error, stack) {
      for (final request in requests) {
        if (!request.completer.isCompleted) request.completer.completeError(error, stack);
      }
    }
  }
}

class _CardRequest {
  _CardRequest(this.owner, this.messageId, this.kind, this.entityId);
  final AuthOperationScope owner;
  final String messageId;
  final String kind;
  final String entityId;
  final completer = Completer<ChatActionCardEntry>();
}
