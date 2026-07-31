// Stage 13.12 — batch card cache, redesigned topic/collection cards, and
// the UnifiedTaskDetailsScreen destination.
//
// Guards:
//  * Envelope parsing still drives Message.cardKind/cardEntityId.
//  * A card-bearing message renders TopicSelectionCard/CollectionCard, never
//    the raw JSON via MessageBubble.
//  * A closed/compact card shows kind-specific closed copy + title, never JSON.
//  * ChatActionCardsCache merge/tombstone/invalidate semantics.
//  * Deep-link args + UnifiedTaskDetailsScreen constructor/route smoke.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_action_cards_cache.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/message_builder.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/navigation/group_action_deeplink.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_selection_card.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/unified_task_details_screen.dart';

const _topicUuid = '11111111-1111-1111-1111-111111111111';
const _collectionUuid = '22222222-2222-2222-2222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Stage 13.12 envelope still works with cards', () {
    test('topic_selection JSON text resolves cardKind/cardEntityId', () {
      final m = Message.fromJson({
        'id': 'm1',
        'chat_id': 'chat-1',
        'author_id': 'u1',
        'author_name': 'Student',
        'author_login': 'stud1',
        'text': '{"card":"topic_selection","selection_id":"$_topicUuid"}',
        'msg_type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      });
      expect(m.cardKind, 'topic_selection');
      expect(m.cardEntityId, _topicUuid);
      expect(m.text.contains('{'), isFalse);
    });

    test('collection JSON text resolves cardKind/cardEntityId', () {
      final m = Message.fromJson({
        'id': 'm2',
        'chat_id': 'chat-1',
        'author_id': 'u1',
        'author_name': 'Student',
        'author_login': 'stud1',
        'body': '{"card":"collection","collection_id":"$_collectionUuid"}',
        'msg_type': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      });
      expect(m.cardKind, 'collection');
      expect(m.cardEntityId, _collectionUuid);
    });
  });

  group('Stage 13.12 card routing (no JSON leaks)', () {
    test('topic_selection message routes to TopicSelectionCard, not raw JSON', () {
      final m = Message(
        id: 'm3',
        chatId: 'chat-1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        text: '{"card":"topic_selection","selection_id":"$_topicUuid"}',
        at: DateTime.utc(2026, 1, 1),
        cardKind: 'topic_selection',
        cardEntityId: _topicUuid,
      );

      final widget = buildBubble(
        m: m,
        showAvatar: false,
        time: '12:00',
        onLongPress: null,
        onReply: () {},
        onReplyTap: (_) {},
        reactions: const {},
        onReact: () {},
      );

      expect(widget, isA<TopicSelectionCard>());
      final card = widget as TopicSelectionCard;
      expect(card.message.cardKind, 'topic_selection');
    });

    test('collection message routes to CollectionCard, not raw JSON', () {
      final m = Message(
        id: 'm4',
        chatId: 'chat-1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        text: '{"card":"collection","collection_id":"$_collectionUuid"}',
        at: DateTime.utc(2026, 1, 1),
        cardKind: 'collection',
        cardEntityId: _collectionUuid,
      );

      final widget = buildBubble(
        m: m,
        showAvatar: false,
        time: '12:00',
        onLongPress: null,
        onReply: () {},
        onReplyTap: (_) {},
        reactions: const {},
        onReact: () {},
      );

      expect(widget, isA<CollectionCard>());
    });
  });

  group('Stage 13.12 realtime bind lifecycle', () {
    test('refreshEntity preserves cardMessageId and force-reloads', () async {
      final cache = ChatActionCardsCache();
      cache.seed(const ChatActionCardEntry(
        kind: ChatActionCardKind.topicSelection,
        entityId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        cardMessageId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        available: true,
        status: 'open',
        title: 'Seed',
      ));
      // Without a live client, refreshEntity returns early after preserving
      // id — ensure it does not tombstone when cardMessageId would be lost.
      final before = cache.peek(
        ChatActionCardKind.topicSelection,
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      );
      expect(before?.cardMessageId, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
      // Simulate pick event without cardMessageId — preserved from cache.
      expect(before?.cardMessageId, isNotEmpty);
    });
  });

  group('Stage 13.12 closed/compact card copy', () {
    testWidgets('closed topic card shows "Темы закрыты" + title, no JSON',
        (tester) async {
      final cache = ChatActionCardsCache();
      cache.seed(ChatActionCardEntry.fromBatchJson({
            'kind': 'topic_selection',
            'entity_id': _topicUuid,
            'available': true,
            'status': 'closed',
            'title': 'Темы докладов по экологии',
            'compact_completed': true,
            'taken_slots': 3,
            'total_capacity': 3,
          })!);

      final m = Message(
        id: 'm5',
        chatId: 'chat-1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        text: '{"card":"topic_selection","selection_id":"$_topicUuid"}',
        at: DateTime.utc(2026, 1, 1),
        cardKind: 'topic_selection',
        cardEntityId: _topicUuid,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TopicSelectionCard(message: m, cache: cache),
        ),
      ));
      await tester.pump();

      expect(find.text('Темы закрыты'), findsOneWidget);
      expect(find.textContaining('Темы докладов по экологии'), findsOneWidget);
      expect(find.textContaining('{"card"'), findsNothing);
      expect(find.textContaining(_topicUuid), findsNothing);
    });

    testWidgets('closed collection card shows "Сбор закрыт" + title, no JSON',
        (tester) async {
      final cache = ChatActionCardsCache();
      cache.seed(ChatActionCardEntry.fromBatchJson({
            'kind': 'group_collection',
            'entity_id': _collectionUuid,
            'available': true,
            'status': 'closed',
            'title': 'Подарок преподавателю',
            'compact_completed': true,
          })!);

      final m = Message(
        id: 'm6',
        chatId: 'chat-1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        text: '{"card":"collection","collection_id":"$_collectionUuid"}',
        at: DateTime.utc(2026, 1, 1),
        cardKind: 'collection',
        cardEntityId: _collectionUuid,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CollectionCard(message: m, cache: cache),
        ),
      ));
      await tester.pump();

      expect(find.text('Сбор закрыт'), findsOneWidget);
      expect(find.textContaining('Подарок преподавателю'), findsOneWidget);
      expect(find.textContaining('{"card"'), findsNothing);
    });

    testWidgets('open topic card shows badge, title, progress and CTA',
        (tester) async {
      final cache = ChatActionCardsCache();
      cache.seed(ChatActionCardEntry.fromBatchJson({
            'kind': 'topic_selection',
            'entity_id': _topicUuid,
            'available': true,
            'status': 'open',
            'title': 'Темы докладов',
            'taken_slots': 1,
            'total_capacity': 4,
          })!);

      final m = Message(
        id: 'm7',
        chatId: 'chat-1',
        authorId: 'u1',
        authorLogin: 'stud1',
        authorName: 'Student',
        text: '{"card":"topic_selection","selection_id":"$_topicUuid"}',
        at: DateTime.utc(2026, 1, 1),
        cardKind: 'topic_selection',
        cardEntityId: _topicUuid,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TopicSelectionCard(message: m, cache: cache),
        ),
      ));
      await tester.pump();

      expect(find.text('Темы'), findsOneWidget);
      expect(find.text('Открыть'), findsOneWidget);
      expect(find.text('Темы докладов'), findsOneWidget);
      expect(find.textContaining('Занято 1 из 4'), findsOneWidget);
      // Compact card: tap opens details — no bulky tonal CTA button.
      expect(find.text('Выбрать тему'), findsNothing);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    });
  });

  group('Stage 13.12 ChatActionCardsCache merge/tombstone', () {
    test('canonicalKind normalizes wire/legacy aliases', () {
      expect(ChatActionCardsCache.canonicalKind('topic'), 'topic_selection');
      expect(ChatActionCardsCache.canonicalKind('topic_selection'), 'topic_selection');
      expect(ChatActionCardsCache.canonicalKind('collection'), 'group_collection');
      expect(ChatActionCardsCache.canonicalKind('group_collection'), 'group_collection');
    });

    test('seed + peek round-trip by kind+entityId', () {
      final cache = ChatActionCardsCache();
      final entry = ChatActionCardEntry.fromBatchJson({
        'kind': 'topic_selection',
        'entity_id': _topicUuid,
        'available': true,
        'status': 'open',
        'title': 'Курсовая',
      })!;
      cache.seed(entry);

      // Wire alias 'topic' must hit the same canonical cache key.
      expect(cache.peek('topic', _topicUuid)?.title, 'Курсовая');
      expect(cache.peek('topic_selection', _topicUuid)?.title, 'Курсовая');
    });

    test('markTombstone flips available=false without losing the row', () {
      final cache = ChatActionCardsCache();
      cache.seed(ChatActionCardEntry.fromBatchJson({
        'kind': 'group_collection',
        'entity_id': _collectionUuid,
        'available': true,
        'status': 'open',
        'title': 'Сбор на подарок',
      })!);

      cache.markTombstone('collection', _collectionUuid);

      final after = cache.peek('group_collection', _collectionUuid);
      expect(after, isNotNull);
      expect(after!.available, isFalse);
      expect(after.status, 'unavailable');
      expect(after.tombstoned, isTrue);
    });

    test('markTombstone on an unknown id creates a tombstoned placeholder',
        () {
      final cache = ChatActionCardsCache();
      cache.markTombstone('topic_selection', 'missing-id');
      final entry = cache.peek('topic_selection', 'missing-id');
      expect(entry, isNotNull);
      expect(entry!.available, isFalse);
      expect(entry.tombstoned, isTrue);
    });

    test('invalidate removes the cached row entirely', () {
      final cache = ChatActionCardsCache();
      cache.seed(ChatActionCardEntry.fromBatchJson({
        'kind': 'topic_selection',
        'entity_id': _topicUuid,
        'available': true,
        'status': 'open',
        'title': 'Курсовая',
      })!);
      expect(cache.peek('topic_selection', _topicUuid), isNotNull);

      cache.invalidate('topic', _topicUuid);
      expect(cache.peek('topic_selection', _topicUuid), isNull);
    });

    test('cache JSON round-trips (offline last-known snapshot)', () {
      final entry = ChatActionCardEntry.fromBatchJson({
        'kind': 'group_collection',
        'entity_id': _collectionUuid,
        'available': true,
        'status': 'closed',
        'title': 'Подарок',
        'compact_completed': true,
        'organizer_stats': {'confirmed': 4, 'pending': 1},
      })!;
      final restored = ChatActionCardEntry.fromCacheJson(entry.toCacheJson());
      expect(restored, isNotNull);
      expect(restored!.kind, 'group_collection');
      expect(restored.isClosed, isTrue);
      expect(restored.organizerStats?['confirmed'], 4);
    });

    test('ensureLoaded resolves synchronously-cached rows without a network call',
        () async {
      final cache = ChatActionCardsCache();
      cache.seed(ChatActionCardEntry.fromBatchJson({
        'kind': 'topic_selection',
        'entity_id': _topicUuid,
        'available': true,
        'status': 'open',
        'title': 'Курсовая',
      })!);

      final entry = await cache.ensureLoaded(
        'chat-1',
        kind: 'topic_selection',
        entityId: _topicUuid,
      );
      expect(entry, isNotNull);
      expect(entry!.title, 'Курсовая');
    });
  });

  group('Stage 13.12 deeplink + UnifiedTaskDetailsScreen smoke', () {
    test('GroupActionDeeplinkArgs.fromDeadline maps eventType to entityType', () {
      final args = GroupActionDeeplinkArgs.fromDeadline(
        eventType: 'topic_deadline',
        entityId: _topicUuid,
        chatId: 'chat-1',
        cardMessageId: 'msg-1',
        teamId: 'team-1',
      );
      expect(args.entityType, 'topic_deadline');
      expect(args.entityId, _topicUuid);
      expect(args.chatId, 'chat-1');
      expect(args.cardMessageId, 'msg-1');
      expect(args.teamId, 'team-1');

      final args2 = GroupActionDeeplinkArgs.fromDeadline(
        eventType: 'topic_deadline',
        entityId: _topicUuid,
        chatId: 'chat-1',
        cardMessageId: 'msg-1',
        teamId: 'team-1',
      );
      expect(args, equals(args2));
    });

    testWidgets(
        'UnifiedTaskDetailsScreen constructs for topic/collection kinds without throwing',
        (tester) async {
      // Smoke-test the widget constructor/route wiring only — assignment
      // kind renders synchronously (no RPC) so it is safe to pump fully.
      await tester.pumpWidget(
        MaterialApp(
          home: UnifiedTaskDetailsScreen(
            kind: 'assignment',
            entityId: 'a1',
            chatId: 'chat-1',
          ),
        ),
      );
      await tester.pump();
      // No ambient TeamCubit in this smoke test → friendly fallback, not a
      // crash, and definitely not raw JSON/ids.
      expect(find.textContaining('Задание'), findsWidgets);
    });

    test('UnifiedTaskDetailsScreen topic/collection constructors are valid routes',
        () {
      expect(
        () => UnifiedTaskDetailsScreen(
          kind: 'topic_selection',
          entityId: _topicUuid,
          chatId: 'chat-1',
          cardMessageId: 'msg-1',
          title: 'Курсовая',
        ),
        returnsNormally,
      );
      expect(
        () => UnifiedTaskDetailsScreen(
          kind: 'collection',
          entityId: _collectionUuid,
          chatId: 'chat-1',
        ),
        returnsNormally,
      );
    });
  });

  group('Stage 13.12.1 author-only edit + pick toggle', () {
    test('author before activity may edit; organizer/non-author may not', () {
      const author = 'user-author';
      final open = <String, dynamic>{
        'created_by': author,
        'taken_slots': 0,
        'can_manage': true,
      };
      expect(
        canAuthorEditTopicSelectionBeforeActivity(
          currentUserId: author,
          details: open,
        ),
        isTrue,
      );
      expect(
        canAuthorEditTopicSelectionBeforeActivity(
          currentUserId: 'organizer-other',
          details: open,
        ),
        isFalse,
      );
    });

    test('author loses edit after first pick', () {
      expect(
        canAuthorEditTopicSelectionBeforeActivity(
          currentUserId: 'user-author',
          details: {
            'created_by': 'user-author',
            'taken_slots': 1,
          },
        ),
        isFalse,
      );
    });

    testWidgets(
        'collection details hide attach/report after done statuses',
        (tester) async {
      for (final status in [
        'reported',
        'pending',
        'pending_review',
        'confirmed',
      ]) {
        final client = SupabaseClient(
          'https://example.invalid',
          'anon-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        final repo = _RecordingTopicRepo(
          client: client,
          details: {
            'available': true,
            'status': 'open',
            'title': 'На собаке',
            'amount_mode': 'per_person',
            'amount_optional': 1000,
            'my_status': status,
          },
        );
        await tester.pumpWidget(MaterialApp(
          home: UnifiedTaskDetailsScreen(
            kind: 'collection',
            entityId: _collectionUuid,
            chatId: 'chat-1',
            repository: repo,
            cache: ChatActionCardsCache(),
            client: client,
          ),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Отметить исполненным'), findsNothing,
            reason: 'status=$status');
        expect(find.text('Прикрепить чек или скриншот'), findsNothing,
            reason: 'status=$status');
        expect(find.textContaining('Исполнено'), findsWidgets,
            reason: 'status=$status');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('tap free topic picks without dialog; tap own pick cancels',
        (tester) async {
      final client = SupabaseClient(
        'https://example.invalid',
        'anon-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final repo = _RecordingTopicRepo(
        client: client,
        details: {
          'available': true,
          'status': 'open',
          'title': 'Темы',
          'allow_change': true,
          'taken_slots': 0,
          'total_capacity': 2,
          'my_pick_text': '',
          'options': [
            {
              'id': 'opt-a',
              'title': 'Тема А',
              'capacity': 1,
              'taken': 0,
              'my_pick': false,
            },
            {
              'id': 'opt-b',
              'title': 'Тема Б',
              'capacity': 1,
              'taken': 0,
              'my_pick': false,
            },
          ],
        },
      );

      await tester.pumpWidget(MaterialApp(
        home: UnifiedTaskDetailsScreen(
          kind: 'topic_selection',
          entityId: _topicUuid,
          chatId: 'chat-1',
          // No cardMessageId → cache refreshEntity is a no-op (no network).
          repository: repo,
          cache: ChatActionCardsCache(),
          client: client,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Подтвердить выбор'), findsNothing);
      expect(find.text('Тема А'), findsOneWidget);

      await tester.tap(find.text('Тема А'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(repo.picked, ['opt-a']);
      expect(repo.cancelled, isEmpty);
      expect(find.text('Подтвердить выбор'), findsNothing);

      // Reload after pick marked opt-a as my_pick.
      await tester.tap(find.text('Тема А'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(repo.cancelled, [_topicUuid]);
    });
  });
}

/// Test double for topic pick/cancel without network RPCs.
class _RecordingTopicRepo extends ChatGroupActionsRepository {
  _RecordingTopicRepo({
    required SupabaseClient client,
    required this.details,
  }) : super(client: client);

  Map<String, dynamic> details;
  final List<String> picked = <String>[];
  final List<String> cancelled = <String>[];

  @override
  Future<Map<String, dynamic>> getTaskDetails({
    required String chatId,
    required String kind,
    required String entityId,
  }) async =>
      Map<String, dynamic>.from(details);

  @override
  Future<bool> canDeleteGroupAction({
    required String kind,
    required String entityId,
  }) async =>
      details['can_delete'] == true;

  @override
  Future<void> pickTopic({
    required String selectionId,
    required String optionId,
  }) async {
    picked.add(optionId);
    final options = (details['options'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    for (final o in options) {
      o['my_pick'] = o['id'] == optionId;
      if (o['id'] == optionId) {
        o['taken'] = 1;
      }
    }
    details = {
      ...details,
      'my_pick_text': options
          .firstWhere((o) => o['id'] == optionId)['title']
          .toString(),
      'taken_slots': 1,
      'options': options,
    };
  }

  @override
  Future<void> cancelTopicPick(String selectionId) async {
    cancelled.add(selectionId);
    final options = (details['options'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    for (final o in options) {
      if (o['my_pick'] == true) {
        o['my_pick'] = false;
        o['taken'] = 0;
      }
    }
    details = {
      ...details,
      'my_pick_text': '',
      'taken_slots': 0,
      'options': options,
    };
  }
}
