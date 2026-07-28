// Stage 13.12 — ChatCardEnvelope / ChatCardPreview coverage.
//
// Guards the root-cause bug: raw card JSON (`{"card":"topic_selection",...}`)
// must never surface as plain text in bubbles / reply / copy / pin / search.

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';

const _topicUuid = '11111111-1111-1111-1111-111111111111';
const _collectionUuid = '22222222-2222-2222-2222-222222222222';
const _assignmentUuid = '33333333-3333-3333-3333-333333333333';

void main() {
  group('ChatCardEnvelope.tryParse', () {
    test('valid topic_selection payload (Map) parses to envelope', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'topic_selection',
        'selection_id': _topicUuid,
      });

      expect(envelope, isNotNull);
      expect(envelope!.kind, ChatCardKind.topicSelection);
      expect(envelope.entityId, _topicUuid);
      expect(envelope.cardKindWire, 'topic_selection');
    });

    test('valid topic_selection payload (JSON string) parses to envelope',
        () {
      final envelope = ChatCardEnvelope.tryParse(
        '{"card":"topic_selection","selection_id":"$_topicUuid"}',
      );

      expect(envelope, isNotNull);
      expect(envelope!.kind, ChatCardKind.topicSelection);
      expect(envelope.entityId, _topicUuid);
    });

    test('valid collection payload parses to envelope', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'collection',
        'collection_id': _collectionUuid,
      });

      expect(envelope, isNotNull);
      expect(envelope!.kind, ChatCardKind.groupCollection);
      expect(envelope.entityId, _collectionUuid);
      expect(envelope.cardKindWire, 'collection');
    });

    test('valid group_collection alias maps to groupCollection kind', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'group_collection',
        'collection_id': _collectionUuid,
      });

      expect(envelope, isNotNull);
      expect(envelope!.kind, ChatCardKind.groupCollection);
      expect(envelope.cardKindWire, 'collection');
    });

    test('valid assignment payload parses to envelope', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'assignment',
        'assignment_id': _assignmentUuid,
      });

      expect(envelope, isNotNull);
      expect(envelope!.kind, ChatCardKind.assignment);
      expect(envelope.entityId, _assignmentUuid);
    });

    test('malformed JSON string returns null, does not throw', () {
      expect(
        () => ChatCardEnvelope.tryParse('{"card": "topic_selection", '),
        returnsNormally,
      );
      expect(ChatCardEnvelope.tryParse('{"card": "topic_selection", '), null);
    });

    test('non-json string returns null', () {
      expect(ChatCardEnvelope.tryParse('Привет, как дела?'), null);
    });

    test('null input returns null', () {
      expect(ChatCardEnvelope.tryParse(null), null);
    });

    test('missing entity id returns null', () {
      final envelope = ChatCardEnvelope.tryParse({'card': 'topic_selection'});
      expect(envelope, null);
    });

    test('invalid (non-UUID) entity id returns null', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'topic_selection',
        'selection_id': 'not-a-uuid',
      });
      expect(envelope, null);
    });

    test('arbitrary user JSON is rejected (not on card allowlist)', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'anything_a_user_could_type',
        'selection_id': _topicUuid,
      });
      expect(envelope, null);

      final envelope2 = ChatCardEnvelope.tryParse({
        'hello': 'world',
        'foo': 42,
      });
      expect(envelope2, null);

      final envelope3 = ChatCardEnvelope.tryParse(
        '{"hello": "I am typing json in chat for fun"}',
      );
      expect(envelope3, null);
    });
  });

  group('ChatCardEnvelope.humanPreview', () {
    test('never contains raw ids / JSON braces', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'topic_selection',
        'selection_id': _topicUuid,
      })!;
      final preview = envelope.humanPreview();
      expect(preview.contains('{'), false);
      expect(preview.contains(_topicUuid), false);
      expect(preview, contains('Выбор темы'));
    });

    test('collection preview is human readable', () {
      final envelope = ChatCardEnvelope.tryParse({
        'card': 'collection',
        'collection_id': _collectionUuid,
      })!;
      expect(envelope.humanPreview(), isNot(contains('{')));
    });
  });

  group('Message.fromJson — card envelope wiring', () {
    test('text=JSON, content missing → cardKind set, text human-readable',
        () {
      // Reproduces the RPC bug: get_chat_messages_page returns
      // text = coalesce(content, body) with no separate `content` field,
      // so the raw jsonb card payload lands directly in `text`.
      final json = {
        'id': 'm1',
        'chat_id': 'c1',
        'author_id': 'u1',
        'author_name': 'Student',
        'author_login': 'stud1',
        'text': '{"card":"topic_selection","selection_id":"$_topicUuid"}',
        'msg_type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      };

      final m = Message.fromJson(json);

      expect(m.cardKind, 'topic_selection');
      expect(m.cardEntityId, _topicUuid);
      expect(m.text.contains('{'), false);
      expect(m.text.contains(_topicUuid), false);
      expect(m.text, contains('Выбор темы'));
    });

    test('body=JSON (no separate text) → cardKind set, text human-readable',
        () {
      final json = {
        'id': 'm2',
        'chat_id': 'c1',
        'author_id': 'u1',
        'author_name': 'Student',
        'author_login': 'stud1',
        'body': '{"card":"collection","collection_id":"$_collectionUuid"}',
        'msg_type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      };

      final m = Message.fromJson(json);

      expect(m.cardKind, 'collection');
      expect(m.cardEntityId, _collectionUuid);
      expect(m.text.contains('{'), false);
      expect(m.text.contains(_collectionUuid), false);
    });

    test('body human + content map → keeps human body, sets cardKind', () {
      final json = {
        'id': 'm3',
        'chat_id': 'c1',
        'author_id': 'u1',
        'author_name': 'Student',
        'author_login': 'stud1',
        'body': 'Выбор темы: Курсовая работа',
        'content': {
          'card': 'topic_selection',
          'selection_id': _topicUuid,
        },
        'msg_type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      };

      final m = Message.fromJson(json);

      expect(m.cardKind, 'topic_selection');
      expect(m.cardEntityId, _topicUuid);
      expect(m.text, 'Выбор темы: Курсовая работа');
    });

    test('plain text message is unaffected (no card)', () {
      final json = {
        'id': 'm4',
        'chat_id': 'c1',
        'author_id': 'u1',
        'author_name': 'Student',
        'author_login': 'stud1',
        'body': 'Привет всем!',
        'msg_type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      };

      final m = Message.fromJson(json);

      expect(m.cardKind, null);
      expect(m.cardEntityId, null);
      expect(m.text, 'Привет всем!');
    });

    test('arbitrary user-typed JSON in text is not treated as a card', () {
      final json = {
        'id': 'm5',
        'chat_id': 'c1',
        'author_id': 'u1',
        'author_name': 'Student',
        'author_login': 'stud1',
        'text': '{"hello": "this looks like json but is not a card"}',
        'msg_type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      };

      final m = Message.fromJson(json);

      expect(m.cardKind, null);
      // Legacy behavior: unrecognized JSON-ish content still surfaces as-is
      // (out of scope for card sanitization), but must not crash / must not
      // be recognized as a card.
      expect(m.text, json['text']);
    });
  });

  group('ChatCardPreview', () {
    test('forMessage never returns selection_id/UUID-only JSON', () {
      final m = Message(
        id: 'm6',
        chatId: 'c1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        // Simulates stale/local cache written before this fix.
        text: '{"card":"topic_selection","selection_id":"$_topicUuid"}',
        at: DateTime.utc(2026, 1, 1),
      );

      final preview = ChatCardPreview.forMessage(m);

      expect(preview.contains('{'), false);
      expect(preview.contains(_topicUuid), false);
      expect(preview, contains('Выбор темы'));
    });

    test('forMessage falls back to sanitized text for non-card messages', () {
      final m = Message(
        id: 'm7',
        chatId: 'c1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        text: 'Обычное сообщение в чате',
        at: DateTime.utc(2026, 1, 1),
      );

      expect(ChatCardPreview.forMessage(m), 'Обычное сообщение в чате');
    });

    test('forMessage uses cardKind/cardEntityId when text is empty', () {
      final m = Message(
        id: 'm8',
        chatId: 'c1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        text: '',
        at: DateTime.utc(2026, 1, 1),
        cardKind: 'collection',
        cardEntityId: _collectionUuid,
      );

      final preview = ChatCardPreview.forMessage(m);
      expect(preview.contains('{'), false);
      expect(preview.contains(_collectionUuid), false);
      expect(preview.isNotEmpty, true);
    });

    test('rejects mismatched kind-specific entity keys', () {
      expect(
        ChatCardEnvelope.tryParse({
          'card': 'topic_selection',
          'collection_id': _collectionUuid,
        }),
        isNull,
      );
      expect(
        ChatCardEnvelope.tryParse({
          'card': 'topic_selection',
          'selection_id': _topicUuid,
          'collection_id': _collectionUuid,
        }),
        isNull,
      );
      expect(
        ChatCardEnvelope.tryParse({
          'card': 'topic_selection',
          'selection_id': _topicUuid,
          'version': 2,
        }),
        isNull,
      );
    });

    test('looksLikeCardJson detects recognized card shapes only', () {
      expect(
        ChatCardPreview.looksLikeCardJson(
          '{"card":"topic_selection","selection_id":"$_topicUuid"}',
        ),
        true,
      );
      expect(
        ChatCardPreview.looksLikeCardJson(
          '{"hello":"world"}',
        ),
        false,
      );
      expect(ChatCardPreview.looksLikeCardJson('Обычный текст'), false);
      expect(ChatCardPreview.looksLikeCardJson(''), false);
    });
  });
}
