import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/data/chat_summary_card.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';

void main() {
  const chat = '11111111-1111-1111-1111-111111111111';
  const message = '22222222-2222-2222-2222-222222222222';
  const entity = '33333333-3333-3333-3333-333333333333';
  Map<String, dynamic> summary(String kind) => {
        'chat_id': chat,
        'last_message_id': message,
        'content': {
          'card': kind,
          if (kind == 'topic_selection') 'selection_id': entity,
          if (kind == 'collection') 'collection_id': entity,
        },
      };

  test('only structured cards get neutral summary labels', () {
    expect(
        summaryCardPreview(
            ChatCardEnvelope.tryParse(summary('topic_selection')['content'])!),
        'Карточка тем');
    expect(
        summaryCardPreview(
            ChatCardEnvelope.tryParse(summary('collection')['content'])!),
        'Карточка сбора');
    expect(
        SummaryActionCard.fromRow(
            {...summary('topic_selection'), 'content': 'Темы'}),
        isNull);
    expect(
        SummaryActionCard.fromRow(
            {...summary('collection'), 'content': 'Сбор'}),
        isNull);
  });

  test('requires last message binding and rejects contradicting envelope id',
      () {
    expect(SummaryActionCard.fromRow(summary('topic_selection')), isNotNull);
    final row = summary('topic_selection');
    (row['content'] as Map)['card_message_id'] = chat;
    expect(SummaryActionCard.fromRow(row), isNull);
    expect(
        SummaryActionCard.fromRow(
            {...summary('collection'), 'last_message_id': ''}),
        isNull);
  });

  test('only one exact, well-formed unavailable row is authoritative', () {
    final card = SummaryActionCard.fromRow(summary('topic_selection'))!;
    Map<String, Object> result(
            {bool available = false, String status = 'unavailable'}) =>
        {
          ...card.rpcItem,
          'available': available,
          'status': status,
        };
    expect(card.explicitlyUnavailable([result()]), isTrue);
    expect(card.explicitlyUnavailable([result(status: 'cancelled')]), isTrue);
    expect(
        card.explicitlyUnavailable([result(available: true, status: 'open')]),
        isFalse);
    expect(
        card.explicitlyUnavailable([result(available: true, status: 'closed')]),
        isFalse);
    expect(
        card.explicitlyUnavailable(
            [result(available: true, status: 'cancelled')]),
        isTrue);
    expect(card.explicitlyUnavailable([]), isFalse);
    expect(card.explicitlyUnavailable([result(), result()]), isFalse);
    expect(card.explicitlyUnavailable([result(status: 'unexpected')]), isFalse);
    expect(
        card.explicitlyUnavailable([
          {...result(), 'entity_id': chat}
        ]),
        isFalse);
    expect(
        card.explicitlyUnavailable([
          {...result(), 'card_message_id': chat}
        ]),
        isFalse);
    expect(
        card.explicitlyUnavailable([
          {...result(), 'available': 'false'}
        ]),
        isFalse);
  });

  test('verification is bounded, failure stays unknown, stale reply ignored',
      () async {
    final cards = List.generate(
        4,
        (i) => SummaryActionCard(
            chatId: '$chat$i',
            messageId: message,
            kind: 'topic_selection',
            entityId: entity));
    final gates = List.generate(4, (_) => Completer<Object?>());
    final called = <int>[];
    final hidden = <int>[];
    var current = true;
    final work = verifySummaryActionCards(cards,
        isCurrent: (_) => current,
        fetch: (card) {
          final index = cards.indexOf(card);
          called.add(index);
          return gates[index].future;
        },
        onUnavailable: (card) => hidden.add(cards.indexOf(card)));
    expect(called, [0, 1]);
    gates[1].completeError(StateError('offline'));
    await Future<void>.delayed(Duration.zero);
    expect(called, [0, 1, 2]);
    gates[2].complete([
      {...cards[2].rpcItem, 'available': false, 'status': 'unavailable'}
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(hidden, [2]);
    expect(called, [0, 1, 2, 3]);
    current = false;
    gates[0].complete([
      {...cards[0].rpcItem, 'available': false, 'status': 'unavailable'}
    ]);
    gates[3].complete([
      {...cards[3].rpcItem, 'available': false, 'status': 'unavailable'}
    ]);
    await work;
    expect(hidden, [2]);
  });

  test('stalled requests time out so later chats are checked', () async {
    final cards = List.generate(
        3,
        (i) => SummaryActionCard(
            chatId: '$chat$i',
            messageId: message,
            kind: 'topic_selection',
            entityId: entity));
    final gates = List.generate(3, (_) => Completer<Object?>());
    final called = <int>[];
    final hidden = <int>[];
    final done = verifySummaryActionCards(cards,
        timeout: const Duration(milliseconds: 20),
        isCurrent: (_) => true,
        fetch: (card) {
          final index = cards.indexOf(card);
          called.add(index);
          return gates[index].future;
        },
        onUnavailable: (card) => hidden.add(cards.indexOf(card)));
    expect(called, [0, 1]);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(called, [0, 1, 2]);
    gates[2].complete([
      {...cards[2].rpcItem, 'available': false, 'status': 'unavailable'}
    ]);
    await done;
    gates[0].complete([
      {...cards[0].rpcItem, 'available': false, 'status': 'unavailable'}
    ]);
    gates[1].complete([
      {...cards[1].rpcItem, 'available': false, 'status': 'unavailable'}
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(hidden, [2]);
  });
}
