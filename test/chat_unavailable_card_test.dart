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
import 'package:student_platform/src/ui/learning/tabs/chat/topics/topic_selection_card.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/chat_group_actions_repository.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/data/strict_chat_card_loader.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _DelayedCardCache extends StrictChatCardLoader {
  final result = Completer<ChatActionCardEntry>();
  @override
  Future<ChatActionCardEntry> load({required AuthSessionScope? scope,
          required String chatId, required String messageId, required String kind,
          required String entityId,
          }) =>
      result.future;
}

class _Repository implements LearningRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RoutingCardLoader extends StrictChatCardLoader {
  final calls = <String, Completer<ChatActionCardEntry>>{};
  @override
  Future<ChatActionCardEntry> load({required AuthSessionScope? scope,
      required String chatId, required String messageId, required String kind,
      required String entityId}) =>
      calls.putIfAbsent(messageId, () => Completer<ChatActionCardEntry>()).future;
}

class _SequenceCardLoader extends StrictChatCardLoader {
  final calls = <Completer<ChatActionCardEntry>>[];
  @override
  Future<ChatActionCardEntry> load({required AuthSessionScope? scope,
      required String chatId, required String messageId, required String kind,
      required String entityId}) {
    final result = Completer<ChatActionCardEntry>();
    calls.add(result);
    return result.future;
  }
}

class _DeleteRepo extends ChatGroupActionsRepository {
  _DeleteRepo() : super(client: SupabaseClient('https://example.test', 'test',
      authOptions: const AuthClientOptions(autoRefreshToken: false)));
  int calls = 0;
  @override
  Future<void> deleteGroupAction({required String kind, required String entityId}) async { calls++; }
}

Message _message(
        {String? kind, String? entity, MessageType type = MessageType.text}) =>
    Message(
        id: '11111111-1111-4111-8111-111111111111',
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

  testWidgets('reused card never displays an old response or another account', (tester) async {
    final previous = StrictChatCardLoader.instance;
    final loader = _RoutingCardLoader();
    StrictChatCardLoader.instance = loader;
    var session = fakeSession('card-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    addTearDown(() async { StrictChatCardLoader.instance = previous; await events.close(); });
    const first = '11111111-1111-4111-8111-111111111111';
    const second = '22222222-2222-4222-8222-222222222222';
    Message card(String messageId, String entity) => Message(id: messageId,
      chatId: 'chat', authorId: 'other', authorLogin: '', authorName: '',
      text: 'Скинуть на собаке', at: DateTime(2026), cardKind: 'collection', cardEntityId: entity);
    Widget screen(Message message) => MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope, child: Scaffold(body: CollectionCard(message: message,
      canManage: false, canDelete: false))));
    await tester.pumpWidget(screen(card(first, 'first')));
    await tester.pump();
    expect(find.textContaining('собаке'), findsNothing);
    await tester.pumpWidget(screen(card(second, 'second')));
    await tester.pump();
    loader.calls[first]!.complete(const ChatActionCardEntry(kind: 'group_collection',
      entityId: 'first', available: true, status: 'open', title: 'Старый чужой заголовок'));
    await tester.pump();
    expect(find.text('Старый чужой заголовок'), findsNothing);
    loader.calls[second]!.complete(const ChatActionCardEntry(kind: 'group_collection',
      entityId: 'second', available: true, status: 'open', title: 'Правильный заголовок'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Правильный заголовок'), findsOneWidget);
    session = fakeSession('card-b'); // change before the auth event is delivered
    await tester.pumpWidget(screen(card(second, 'second')));
    await tester.pump();
    expect(find.text('Правильный заголовок'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('account change during delete dialog never executes mutation', (tester) async {
    final previous = StrictChatCardLoader.instance;
    final loader = _RoutingCardLoader();
    StrictChatCardLoader.instance = loader;
    var session = fakeSession('card-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    addTearDown(() async { StrictChatCardLoader.instance = previous; await events.close(); });
    final repo = _DeleteRepo();
    const id = '11111111-1111-4111-8111-111111111111';
    final message = Message(id: id, chatId: 'chat', authorId: 'a', authorLogin: '',
      authorName: '', text: '', at: DateTime(2026), cardKind: 'collection', cardEntityId: 'entity');
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: Scaffold(body: CollectionCard(message: message, repository: repo,
        canManage: true, canDelete: true)))));
    await tester.pump();
    loader.calls[id]!.complete(const ChatActionCardEntry(kind: 'group_collection', entityId: 'entity',
      available: true, status: 'open', title: 'Тест', canDelete: true));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    session = fakeSession('card-b');
    await tester.tap(find.text('Удалить').last);
    await tester.pumpAndSettle();
    expect(repo.calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('assignment with missing id is hidden',
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
    expect(find.text('Карточка недоступна'), findsNothing);
  });

  testWidgets('hidden first card keeps the date for a real message', (tester) async {
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => Supabase.initialize(url: 'https://example.test', publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false)));
    addTearDown(() async => Supabase.instance.dispose());
    final previous = StrictChatCardLoader.instance;
    final loader = _DelayedCardCache();
    StrictChatCardLoader.instance = loader;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('test-user');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    addTearDown(() async { StrictChatCardLoader.instance = previous; await events.close(); });
    final controller = ScrollController();
    final search = ChatSearchController();
    addTearDown(controller.dispose);
    addTearDown(search.dispose);
    final regular = Message(id: 'second', chatId: 'chat', authorId: 'other',
      authorLogin: '', authorName: 'Друг', text: 'Реальное сообщение', at: DateTime(2026, 7, 28, 1));
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: Scaffold(body: ChatMessageList(
        messages: [_message(kind: 'collection', entity: 'entity'), regular],
        controller: controller, messageKeys: {}, search: search, currentUserId: 'test-user',
        onReply: (_) {}, onLongPress: (_, __, ___, ____, _____, ______) {},
        onReplyTap: (_) {}, onReact: (_, __) {}, selectingMessages: false,
        selectedMessageIds: const {}, onToggleSelect: (_) {},
        canModerateCollection: false, canDeleteGroupAction: false,
      )))));
    await tester.pump();
    loader.result.complete(const ChatActionCardEntry(kind: 'collection', entityId: 'entity',
      available: false, status: 'cancelled', tombstoned: true));
    await tester.pump();
    await tester.pump();
    expect(find.text('Реальное сообщение'), findsOneWidget);
    expect(find.text('28 июля 2026'), findsOneWidget);
    expect(find.text('Карточка недоступна'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old account response cannot expose a card or date after account switch', (tester) async {
    await initializeDateFormatting('ru');
    final previous = StrictChatCardLoader.instance;
    final loader = _SequenceCardLoader();
    StrictChatCardLoader.instance = loader;
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('account-a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    addTearDown(() async { StrictChatCardLoader.instance = previous; await events.close(); });
    final controller = ScrollController();
    final search = ChatSearchController();
    addTearDown(controller.dispose);
    addTearDown(search.dispose);
    Widget screen(String owner) => MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: Scaffold(body: ChatMessageList(
        messages: [_message(kind: 'collection', entity: 'entity')],
        controller: controller, messageKeys: {}, search: search, currentUserId: owner,
        onReply: (_) {}, onLongPress: (_, __, ___, ____, _____, ______) {},
        onReplyTap: (_) {}, onReact: (_, __) {}, selectingMessages: false,
        selectedMessageIds: const {}, onToggleSelect: (_) {},
        canModerateCollection: false, canDeleteGroupAction: false,
      ))));
    await tester.pumpWidget(screen('account-a'));
    await tester.pump();
    expect(loader.calls, hasLength(1));
    session = fakeSession('account-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pumpWidget(screen('account-b'));
    await tester.pump();
    expect(loader.calls, hasLength(2));
    loader.calls.first.complete(const ChatActionCardEntry(kind: 'collection', entityId: 'entity',
      available: true, status: 'open', title: 'Старая карточка'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Старая карточка'), findsNothing);
    expect(find.text('28 июля 2026'), findsNothing);
    loader.calls.last.complete(const ChatActionCardEntry(kind: 'collection', entityId: 'entity',
      available: true, status: 'open', title: 'Актуальная карточка'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('Актуальная карточка'), findsOneWidget);
    expect(find.text('28 июля 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('network error stays visible during retry and a recovered card appears', (tester) async {
    await initializeDateFormatting('ru');
    final previous = StrictChatCardLoader.instance;
    final loader = _SequenceCardLoader();
    StrictChatCardLoader.instance = loader;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('test-user');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    addTearDown(() async { StrictChatCardLoader.instance = previous; await events.close(); });
    final controller = ScrollController();
    final search = ChatSearchController();
    addTearDown(controller.dispose);
    addTearDown(search.dispose);
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: Scaffold(body: ChatMessageList(
        messages: [_message(kind: 'collection', entity: 'entity')],
        controller: controller, messageKeys: {}, search: search, currentUserId: 'test-user',
        onReply: (_) {}, onLongPress: (_, __, ___, ____, _____, ______) {},
        onReplyTap: (_) {}, onReact: (_, __) {}, selectingMessages: false,
        selectedMessageIds: const {}, onToggleSelect: (_) {},
        canModerateCollection: false, canDeleteGroupAction: false,
      )))));
    await tester.pump();
    loader.calls.first.completeError(TimeoutException('offline'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('Не удалось загрузить карточку'), findsOneWidget);
    await tester.tap(find.text('Не удалось загрузить карточку'));
    await tester.pump();
    expect(loader.calls, hasLength(2));
    expect(find.text('Не удалось загрузить карточку'), findsOneWidget);
    loader.calls.last.complete(const ChatActionCardEntry(kind: 'collection', entityId: 'entity',
      available: true, status: 'open', title: 'Актуальная карточка'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Актуальная карточка'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('card mounted before initialSession becomes visible when scope is ready', (tester) async {
    await initializeDateFormatting('ru');
    final previous = StrictChatCardLoader.instance;
    final loader = _SequenceCardLoader();
    StrictChatCardLoader.instance = loader;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('test-user');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    addTearDown(() async { StrictChatCardLoader.instance = previous; await events.close(); });
    final controller = ScrollController();
    final search = ChatSearchController();
    addTearDown(controller.dispose);
    addTearDown(search.dispose);
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: Scaffold(body: ChatMessageList(
        messages: [_message(kind: 'collection', entity: 'entity')],
        controller: controller, messageKeys: {}, search: search, currentUserId: 'test-user',
        onReply: (_) {}, onLongPress: (_, __, ___, ____, _____, ______) {},
        onReplyTap: (_) {}, onReact: (_, __) {}, selectingMessages: false,
        selectedMessageIds: const {}, onToggleSelect: (_) {},
        canModerateCollection: false, canDeleteGroupAction: false,
      )))));
    await tester.pump();
    expect(loader.calls, isEmpty);
    expect(find.text('28 июля 2026'), findsNothing);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    await tester.pump();
    await tester.pump();
    expect(loader.calls, hasLength(1));
    loader.calls.single.complete(const ChatActionCardEntry(kind: 'collection', entityId: 'entity',
      available: true, status: 'open', title: 'Доступная карточка'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('Доступная карточка'), findsOneWidget);
    expect(find.text('28 июля 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final kind in ['topic_selection', 'collection']) {
    testWidgets('$kind tombstone hides the card and orphan date',
        (tester) async {
      await initializeDateFormatting('ru');
      final oldCache = StrictChatCardLoader.instance;
      final cache = _DelayedCardCache();
      StrictChatCardLoader.instance = cache;
      final events = StreamController<AuthState>.broadcast(sync: true);
      final session = fakeSession('test-user');
      final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      addTearDown(() async { StrictChatCardLoader.instance = oldCache; await events.close(); });
      final controller = ScrollController();
      final search = ChatSearchController();
      addTearDown(controller.dispose);
      addTearDown(search.dispose);
      await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope, child:
        Scaffold(
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
      )))));
      await tester.pump();
      expect(find.text('28 июля 2026'), findsNothing);
      expect(find.text('Карточка недоступна'), findsNothing);
      cache.result.complete(ChatActionCardEntry(
          kind: kind,
          entityId: 'entity',
          available: false,
          status: 'cancelled',
          tombstoned: true));
      await tester.pump();
      await tester.pump();
      expect(find.text('28 июля 2026'), findsNothing);
      expect(find.text('Карточка недоступна'), findsNothing);
      expect(find.text('Старое название'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$kind resolved card appears together with date', (tester) async {
      await initializeDateFormatting('ru');
      final previous = StrictChatCardLoader.instance;
      final loader = _DelayedCardCache();
      StrictChatCardLoader.instance = loader;
      final events = StreamController<AuthState>.broadcast(sync: true);
      final session = fakeSession('test-user');
      final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      addTearDown(() async { StrictChatCardLoader.instance = previous; await events.close(); });
      final controller = ScrollController();
      final search = ChatSearchController();
      addTearDown(controller.dispose);
      addTearDown(search.dispose);
      await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
        child: Scaffold(body: ChatMessageList(
          messages: [_message(kind: kind, entity: 'entity')],
          controller: controller, messageKeys: {}, search: search, currentUserId: 'test-user',
          onReply: (_) {}, onLongPress: (_, __, ___, ____, _____, ______) {},
          onReplyTap: (_) {}, onReact: (_, __) {}, selectingMessages: false,
          selectedMessageIds: const {}, onToggleSelect: (_) {},
          canModerateCollection: false, canDeleteGroupAction: false,
        )))));
      await tester.pump();
      expect(find.text('28 июля 2026'), findsNothing);
      loader.result.complete(ChatActionCardEntry(
        kind: kind, entityId: 'entity', available: true, status: 'open', title: 'Актуальная карточка'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.text('Актуальная карточка'), findsOneWidget);
      expect(find.text('28 июля 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
