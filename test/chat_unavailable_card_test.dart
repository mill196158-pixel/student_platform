import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/assignment_bubble.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_action_cards_cache.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';

class _DelayedCardCache extends ChatActionCardsCache {
  final result = Completer<ChatActionCardEntry?>();
  @override
  Future<ChatActionCardEntry?> ensureLoaded(String chatId,
          {required String kind,
          required String entityId,
          String? cardMessageId,
          bool forceNetwork = false}) =>
      result.future;
}

class _Repository implements LearningRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Message _message(
        {String? kind, String? entity, MessageType type = MessageType.text}) =>
    Message(
        id: 'message',
        chatId: 'chat',
        authorId: 'other',
        authorLogin: '',
        authorName: 'Друг',
        text: 'Старое название',
        at: DateTime(2026, 7, 28),
        type: type,
        cardKind: kind,
        cardEntityId: entity);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('assignment with missing id has an explanatory placeholder',
      (tester) async {
    final cubit = TeamCubit(
        const Team(id: 't', name: '', teacher: '', groupCode: '', icon: ''),
        repository: _Repository());
    addTearDown(cubit.close);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BlocProvider.value(
                value: cubit,
                child: AssignmentBubble(
                    message: _message(type: MessageType.assignmentPublished),
                    isDraft: false,
                    time: '12:00')))));
    expect(find.text('Карточка недоступна'), findsOneWidget);
  });

  for (final kind in ['topic_selection', 'collection']) {
    testWidgets('$kind tombstone renders content below its date',
        (tester) async {
      await initializeDateFormatting('ru');
      final oldCache = ChatActionCardsCache.instance;
      final cache = _DelayedCardCache();
      ChatActionCardsCache.instance = cache;
      addTearDown(() => ChatActionCardsCache.instance = oldCache);
      final controller = ScrollController();
      final search = ChatSearchController();
      addTearDown(controller.dispose);
      addTearDown(search.dispose);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ChatMessageList(
        messages: [_message(kind: kind, entity: 'entity')],
        controller: controller,
        messageKeys: {},
        search: search,
        currentUserId: 'me',
        onReply: (_) {},
        onLongPress: (_, __, ___, ____, _____, ______) {},
        onReplyTap: (_) {},
        onReact: (_, __) {},
        selectingMessages: false,
        selectedMessageIds: const {},
        onToggleSelect: (_) {},
        canModerateCollection: false,
        canDeleteGroupAction: false,
      ))));
      await tester.pump();
      cache.result.complete(ChatActionCardEntry(
          kind: kind,
          entityId: 'entity',
          available: false,
          status: 'cancelled',
          tombstoned: true));
      await tester.pump();
      await tester.pump();
      expect(find.text('28 июля 2026'), findsOneWidget);
      expect(find.text('Карточка недоступна'), findsOneWidget);
      expect(find.text('Старое название'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
