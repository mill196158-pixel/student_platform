// =============================
// FILE: lib/src/ui/learning/tabs/chat/models/chat_card_envelope.dart
// =============================
//
// Stage 13.12 — strict parser for structured chat "card" payloads
// (topic selection / group collection / assignment cards).
//
// Root cause this file fixes: some server paths only return a raw
// `text`/`body` column that ends up containing the jsonb `content`
// payload (e.g. `{"card":"topic_selection","selection_id":"…"}`)
// with no separate structured `content` field. Without this parser
// that raw JSON leaks into chat bubbles / reply / copy / pin / search
// previews as plain text. [ChatCardEnvelope.tryParse] is a strict
// allowlist parser: it never accepts arbitrary user-authored JSON as
// a card, and [ChatCardPreview] guarantees a human-readable string is
// shown wherever message text is surfaced.

import 'dart:convert';

import '../../../models/message.dart';

enum ChatCardKind { assignment, topicSelection, groupCollection }

/// Result of resolving a message's display text + card metadata from
/// raw server fields (body/text/content). Used by [Message.fromJson]
/// and the Supabase repository's row mapper so both stay in sync.
class ChatCardResolvedText {
  final String text;
  final String? cardKind;
  final String? cardEntityId;

  const ChatCardResolvedText({
    required this.text,
    this.cardKind,
    this.cardEntityId,
  });
}

class ChatCardEnvelope {
  final ChatCardKind kind;
  final String entityId; // UUID (selection_id | collection_id | assignment_id)
  final String? cardMessageId;
  final int version; // schema version, default 1

  const ChatCardEnvelope({
    required this.kind,
    required this.entityId,
    this.cardMessageId,
    this.version = 1,
  });

  static final RegExp _uuidRegExp = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool isValidUuid(String? value) {
    if (value == null) return false;
    final v = value.trim();
    if (v.isEmpty) return false;
    return _uuidRegExp.hasMatch(v);
  }

  /// Strict allowlist parser. Accepts a `Map` (already-decoded content)
  /// or a JSON-encoded `String`. Returns null for anything that is not
  /// a recognized card shape — including arbitrary user-authored JSON,
  /// missing/invalid entity ids, or unknown `card` values.
  static ChatCardEnvelope? tryParse(dynamic raw) {
    if (raw == null) return null;

    Map<String, dynamic>? map;
    if (raw is Map) {
      map = Map<String, dynamic>.from(raw);
    } else if (raw is String) {
      final s = raw.trim();
      if (s.isEmpty || !s.startsWith('{') || !s.endsWith('}')) return null;
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map) {
          map = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        return null;
      }
    }
    if (map == null) return null;

    final cardRaw = map['card']?.toString().trim();
    if (cardRaw == null || cardRaw.isEmpty) return null;

    ChatCardKind kind;
    switch (cardRaw) {
      case 'topic_selection':
        kind = ChatCardKind.topicSelection;
        break;
      case 'collection':
      case 'group_collection':
        kind = ChatCardKind.groupCollection;
        break;
      case 'assignment':
        kind = ChatCardKind.assignment;
        break;
      default:
        // Reject anything outside the strict allowlist.
        return null;
    }

    // Kind-specific entity key — reject mismatched / conflicting ids.
    String? entityIdRaw;
    switch (kind) {
      case ChatCardKind.topicSelection:
        entityIdRaw = map['selection_id']?.toString().trim();
        if (map.containsKey('collection_id') ||
            map.containsKey('assignment_id')) {
          return null;
        }
        break;
      case ChatCardKind.groupCollection:
        entityIdRaw = map['collection_id']?.toString().trim();
        if (map.containsKey('selection_id') ||
            map.containsKey('assignment_id')) {
          return null;
        }
        break;
      case ChatCardKind.assignment:
        entityIdRaw = map['assignment_id']?.toString().trim();
        if (map.containsKey('selection_id') ||
            map.containsKey('collection_id')) {
          return null;
        }
        break;
    }
    if (!isValidUuid(entityIdRaw)) return null;

    final cardMessageIdRaw = map['card_message_id']?.toString().trim();
    final cardMessageId =
        isValidUuid(cardMessageIdRaw) ? cardMessageIdRaw : null;

    int version = 1;
    final versionRaw = map['v'] ?? map['version'];
    if (versionRaw != null) {
      final parsed =
          versionRaw is int ? versionRaw : int.tryParse(versionRaw.toString());
      if (parsed == null) return null;
      version = parsed;
    }
    // Only schema version 1 is supported.
    if (version != 1) return null;

    return ChatCardEnvelope(
      kind: kind,
      entityId: entityIdRaw!,
      cardMessageId: cardMessageId,
      version: version,
    );
  }

  /// Wire string compatible with `Message.cardKind` / message_builder.dart
  /// (`topic_selection` | `collection` | `assignment`).
  String get cardKindWire {
    switch (kind) {
      case ChatCardKind.topicSelection:
        return 'topic_selection';
      case ChatCardKind.groupCollection:
        return 'collection';
      case ChatCardKind.assignment:
        return 'assignment';
    }
  }

  /// Human-readable, never-JSON preview text for this card.
  String humanPreview({String? title}) {
    final t = (title ?? '').trim();
    switch (kind) {
      case ChatCardKind.topicSelection:
        return t.isNotEmpty ? 'Выбор темы: $t' : 'Выбор темы';
      case ChatCardKind.groupCollection:
        return t.isNotEmpty ? 'Скинуться: $t' : 'Скинуться';
      case ChatCardKind.assignment:
        return t.isNotEmpty ? 'Задание: $t' : 'Задание';
    }
  }

  /// Resolves display text + card metadata from raw server row fields.
  /// Shared by `Message.fromJson` and the Supabase repository mapper so
  /// both surfaces apply identical (strict, JSON-never-leaks) logic.
  static ChatCardResolvedText resolveTextAndCard({
    String? body,
    String? text,
    dynamic content,
    bool isForward = false,
  }) {
    final bodyVal = (body ?? '').trim().isEmpty ? '' : body!.trim();
    final textVal = (text ?? '').trim().isEmpty ? '' : text!.trim();
    String resolvedText = bodyVal.isNotEmpty ? bodyVal : textVal;

    if (isForward) {
      return ChatCardResolvedText(text: resolvedText);
    }

    ChatCardEnvelope? envelope = tryParse(content);
    envelope ??= tryParse(bodyVal.isNotEmpty ? bodyVal : null);
    envelope ??= tryParse(textVal.isNotEmpty ? textVal : null);

    if (envelope == null) {
      // Recognized card key but failed strict validation → never show JSON.
      if (ChatCardPreview.looksLikeCardJson(resolvedText) ||
          ChatCardPreview.looksLikeCardJson(content?.toString() ?? '')) {
        return const ChatCardResolvedText(text: 'Сообщение недоступно');
      }
      // Legacy fallback: plain (non-card) string content with no body/text.
      if (resolvedText.isEmpty && content is String) {
        resolvedText = content;
      }
      return ChatCardResolvedText(text: resolvedText);
    }

    if (ChatCardPreview.looksLikeCardJson(resolvedText) ||
        resolvedText.trim().isEmpty) {
      resolvedText = envelope.humanPreview();
    }

    return ChatCardResolvedText(
      text: resolvedText,
      cardKind: envelope.cardKindWire,
      cardEntityId: envelope.entityId,
    );
  }
}

/// Guarantees that any surface displaying `Message.text` (bubble, reply
/// preview, copy, pin banner, search results) never shows raw card JSON.
class ChatCardPreview {
  static const Set<String> _allowedCards = {
    'topic_selection',
    'collection',
    'group_collection',
    'assignment',
  };

  /// True if [text] parses as JSON with a recognized `card` allowlist key.
  /// Used defensively even after Message parsing, in case cached/local
  /// data predates this fix.
  static bool looksLikeCardJson(String text) {
    final s = text.trim();
    if (s.length < 2 || !s.startsWith('{') || !s.endsWith('}')) return false;
    try {
      final decoded = jsonDecode(s);
      if (decoded is! Map) return false;
      final card = decoded['card']?.toString();
      return card != null && _allowedCards.contains(card);
    } catch (_) {
      return false;
    }
  }

  /// Never returns JSON. Uses the recognized envelope's human preview when
  /// [Message.text] still looks like card JSON (defensive, e.g. stale local
  /// cache), otherwise falls back to the already-sanitized message text.
  static String forMessage(Message m) {
    final text = m.text;

    if (looksLikeCardJson(text)) {
      final envelope = ChatCardEnvelope.tryParse(text);
      if (envelope != null) return envelope.humanPreview();
      return 'Сообщение';
    }

    if (text.trim().isEmpty) {
      final kind = (m.cardKind ?? '').trim();
      final entityId = (m.cardEntityId ?? '').trim();
      if (kind.isNotEmpty && entityId.isNotEmpty) {
        final map = <String, dynamic>{'card': kind};
        switch (kind) {
          case 'topic_selection':
            map['selection_id'] = entityId;
            break;
          case 'collection':
          case 'group_collection':
            map['collection_id'] = entityId;
            break;
          case 'assignment':
            map['assignment_id'] = entityId;
            break;
        }
        final envelope = ChatCardEnvelope.tryParse(map);
        if (envelope != null) return envelope.humanPreview();
      }
    }

    return text;
  }
}
