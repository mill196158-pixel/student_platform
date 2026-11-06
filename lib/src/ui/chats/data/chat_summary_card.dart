import 'dart:convert';

import '../../learning/tabs/chat/models/chat_card_envelope.dart';
import '../core/forward_payload.dart';

/// Returns a neutral preview only when the complete forward envelope is valid.
String? summaryForwardPreview(Object? value) {
  if (value is Map) return summaryForwardPreview(value['text']);
  if (value is! String) return null;
  final text = value.trim();
  final forward = ForwardPayload.tryParse(text);
  if (forward != null && forward.fromChatId.isNotEmpty &&
      forward.items.isNotEmpty &&
      forward.items.every((item) => item.messageId.isNotEmpty)) {
    final count = forward.items.length;
    return count > 1 ? 'Пересланные сообщения ($count)' : 'Пересланное сообщение';
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return summaryForwardPreview(decoded['text']);
  } catch (_) {}
  return null;
}

bool isSummaryActionCard(Map row) {
  final envelope = ChatCardEnvelope.tryParse(row['content']) ??
      ChatCardEnvelope.tryParse(row['body']);
  return envelope != null && envelope.kind != ChatCardKind.assignment;
}

/// Only structured action messages participate; ordinary text stays untouched.
String summaryCardPreview(ChatCardEnvelope envelope) {
  switch (envelope.kind) {
    case ChatCardKind.topicSelection:
      return 'Карточка тем';
    case ChatCardKind.groupCollection:
      return 'Карточка сбора';
    case ChatCardKind.assignment:
      return envelope.humanPreview();
  }
}

class SummaryActionCard {
  const SummaryActionCard({
    required this.chatId,
    required this.messageId,
    required this.kind,
    required this.entityId,
  });
  final String chatId;
  final String messageId;
  final String kind;
  final String entityId;

  static SummaryActionCard? fromRow(Map<String, dynamic> row) {
    final chat = (row['chat_id'] ?? '').toString();
    final message = (row['last_message_id'] ?? '').toString();
    final contentEnvelope = ChatCardEnvelope.tryParse(row['content']);
    final raw = contentEnvelope != null ? row['content'] : row['body'];
    final envelope = contentEnvelope ?? ChatCardEnvelope.tryParse(raw);
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = null;
      }
    }
    final explicitId = decoded is Map ? decoded['card_message_id'] : null;
    if (envelope == null ||
        envelope.kind == ChatCardKind.assignment ||
        !ChatCardEnvelope.isValidUuid(chat) ||
        !ChatCardEnvelope.isValidUuid(message) ||
        (explicitId != null && explicitId != message) ||
        (envelope.cardMessageId != null && envelope.cardMessageId != message)) {
      return null;
    }
    return SummaryActionCard(
        chatId: chat,
        messageId: message,
        kind: envelope.kind == ChatCardKind.topicSelection
            ? 'topic_selection'
            : 'group_collection',
        entityId: envelope.entityId);
  }

  Map<String, Object> get rpcItem => {
        'kind': kind,
        'entity_id': entityId,
        'card_message_id': messageId,
      };

  /// Only an unambiguous matching server response can declare unavailability.
  bool explicitlyUnavailable(Object? response) {
    if (response is! List || response.length != 1 || response.single is! Map) {
      return false;
    }
    final row = response.single as Map;
    final rawKind = row['kind'];
    final normalizedKind = rawKind == 'topic'
        ? 'topic_selection'
        : rawKind == 'collection'
            ? 'group_collection'
            : rawKind;
    if (normalizedKind != kind ||
        row['entity_id'] != entityId ||
        row['card_message_id'] != messageId ||
        row['available'] is! bool ||
        row['status'] is! String) return false;
    final available = row['available'] as bool;
    final status = row['status'] as String;
    if (!const {
      'draft',
      'open',
      'closed',
      'completed',
      'cancelled',
      'unavailable'
    }.contains(status)) return false;
    if (status == 'cancelled') return true;
    if (available && status == 'unavailable') {
      return false;
    }
    return !available;
  }
}

/// Verify only the latest action per chat, with bounded concurrency.
/// Errors and ambiguous responses never become a confirmed removal.
Future<void> verifySummaryActionCards(
  List<SummaryActionCard> cards, {
  required Future<Object?> Function(SummaryActionCard) fetch,
  required bool Function(SummaryActionCard) isCurrent,
  required void Function(SummaryActionCard) onUnavailable,
  Duration timeout = const Duration(seconds: 8),
}) async {
  var next = 0;
  Future<void> worker() async {
    while (next < cards.length) {
      final card = cards[next++];
      if (!isCurrent(card)) return;
      try {
        final result = await fetch(card).timeout(timeout);
        if (isCurrent(card) && card.explicitlyUnavailable(result)) {
          onUnavailable(card);
        }
      } catch (_) {
        // Unknown state remains a neutral card type.
      }
    }
  }

  await Future.wait(List.generate(cards.length.clamp(0, 2), (_) => worker()));
}
