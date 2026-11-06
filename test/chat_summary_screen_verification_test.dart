import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/chats/data/chat_summaries_cache.dart';
import 'package:student_platform/src/ui/chats/data/chat_warm_coordinator.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'home_progressive_loading_test.dart' show signIn;

const chat = '11111111-1111-1111-1111-111111111111';
const message = '22222222-2222-2222-2222-222222222222';
const entity = '33333333-3333-3333-3333-333333333333';

class _ThrowingPrewarmCache implements ProjectChatServerCache {
  _ThrowingPrewarmCache(this.scope);
  @override final AuthSessionScope scope;
  final called = Completer<void>();
  @override Future<ProjectChatPageTicket?> begin(String chat, {bool Function()? isCurrent}) async => null;
  @override Future<List<Message>?> readForOnlinePrewarm(String chat, SessionCapabilities capabilities) async {
    called.complete();
    throw StateError('synthetic SQLite failure');
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Completer<http.Response> cardResponse;
  late Completer<void> cardRequested;
  var groupMode = false;
  Completer<http.Response>? summaryGate;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://test.invalid',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('get_my_chat_summaries')) {
            final gate = summaryGate;
            if (gate != null) {
              final response = await gate.future;
              return http.Response(response.body, response.statusCode,
                  request: request, headers: response.headers);
            }
            return http.Response(
                jsonEncode([
                  {
                    'chat_id': chat,
                    'chat_type': 'team_main',
                    'team_id': chat,
                    'team_name': groupMode ? '1-См-2' : 'Тестовый чат',
                    'team_group_name': groupMode ? '1-См-2' : '',
                    'team_kind': groupMode ? 'group_space' : 'subject',
                    'title': groupMode ? '1-См-2' : 'Тестовый чат',
                    'last_message_id': message,
                    'last_author_name': 'Автор',
                    'last_message_at': '2026-07-28T12:00:00Z',
                    'settings_exists': true,
                    'content': {
                      'card': 'topic_selection',
                      'selection_id': entity
                    },
                  }
                ]),
                200,
                request: request,
                headers: {'content-type': 'application/json'});
          }
          if (request.url.path.endsWith('get_chat_action_cards_batch')) {
            if (!cardRequested.isCompleted) cardRequested.complete();
            final response = await cardResponse.future;
            return http.Response(response.body, response.statusCode,
                request: request, headers: response.headers);
          }
          return http.Response('[]', 200,
              request: request, headers: {'content-type': 'application/json'});
        }));
    await signIn(Supabase.instance.client, 'owner');
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatSummariesCache.clearMemory();
    cardResponse = Completer<http.Response>();
    cardRequested = Completer<void>();
    groupMode = false;
    summaryGate = null;
  });
  tearDownAll(() => Supabase.instance.dispose());

  testWidgets('same route removes old owner list on account switch', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final client = Supabase.instance.client;
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, client.auth.currentSession));
    await ChatSummariesCache.write('owner', jsonEncode([{
      'team': {'id': 'one', 'name': 'Owner A', 'teacher': '', 'groupCode': '',
        'icon': '', 'kind': 'subject'},
      'title': 'Owner A', 'isDm': false, 'unread': 0,
      'pinned': false, 'muted': false,
    }]));
    summaryGate = Completer<http.Response>();
    final subscribed = <String>[];
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope, child: MyChatsScreen(onRealtimeSubscribe: subscribed.add))));
    expect(find.text('Owner A'), findsOneWidget);
    await tester.runAsync(() => signIn(client, 'other'));
    events.add(AuthState(AuthChangeEvent.signedIn, client.auth.currentSession));
    await tester.pump();
    expect(find.text('Owner A'), findsNothing);
    summaryGate!.complete(http.Response(jsonEncode([{
      'chat_type': 'team_main', 'team_kind': 'subject', 'team_id': 'b-team',
      'team_name': 'Owner B', 'title': 'Owner B', 'settings_exists': true,
    }]), 200, headers: {'content-type': 'application/json'}));
    for (var i = 0; i < 10; i++) { await tester.pump(const Duration(milliseconds: 50)); }
    expect(find.text('Owner A'), findsNothing);
    expect(find.text('Owner B'), findsOneWidget);
    expect(subscribed, contains('other'));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => signIn(client, 'owner'));
    await events.close();
  });

  testWidgets('account switch with failed refresh leaves no endless loading', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final client = Supabase.instance.client;
    final scope = AuthSessionScope(currentSession: () => client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, client.auth.currentSession));
    await ChatSummariesCache.write('owner', jsonEncode([{
      'team': {'id': 'one', 'name': 'Owner A', 'teacher': '', 'groupCode': '',
        'icon': '', 'kind': 'subject'}, 'title': 'Owner A', 'isDm': false,
    }]));
    summaryGate = Completer<http.Response>();
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope, child: const MyChatsScreen(enableRealtime: false))));
    expect(find.text('Owner A'), findsOneWidget);
    await tester.runAsync(() => signIn(client, 'other'));
    events.add(AuthState(AuthChangeEvent.signedIn, client.auth.currentSession));
    await tester.pump();
    summaryGate!.complete(http.Response('{"message":"offline"}', 503,
        headers: {'content-type': 'application/json'}));
    for (var i = 0; i < 20; i++) { await tester.pump(const Duration(milliseconds: 50)); }
    expect(find.text('Owner A'), findsNothing);
    expect(find.byType(ProductLoadingIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => signIn(client, 'owner'));
    await events.close();
  });

  testWidgets('ordinary warm writer feeds the first cached frame', (tester) async {
    groupMode = true;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = Supabase.instance.client.auth.currentSession;
    final scope = AuthSessionScope(
        currentSession: () => Supabase.instance.client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    await tester.runAsync(() async {
      ChatWarmCoordinator.instance.start();
      await ChatWarmCoordinator.instance.refreshNow(force: true);
      ChatWarmCoordinator.instance.stop();
    });
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope,
      child: const MyChatsScreen(enableRealtime: false))));
    expect(find.text('Чат группы'), findsOneWidget);
    expect(find.text('1-См-2'), findsNothing);
    expect(find.text('Карточка тем'), findsNothing);
    cardResponse.complete(http.Response('[]', 200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    await events.close();
  });

  testWidgets('first cached frame uses group identity and hides unverified card', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = Supabase.instance.client.auth.currentSession;
    final scope = AuthSessionScope(
        currentSession: () => Supabase.instance.client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    await ChatSummariesCache.write('owner', jsonEncode([{
      'team': {'id': chat, 'name': '1-См-2', 'groupCode': '1-См-2',
        'teacher': '', 'icon': '', 'kind': 'group_space'},
      'title': '1-См-2', 'subtitle': '1-См-2 · общий чат',
      'lastAuthor': 'Автор', 'lastMsgPreview': 'Карточка тем',
      'lastActionCard': true, 'chatId': chat, 'lastMessageId': message,
      'unread': 0, 'pinned': false, 'muted': false, 'isDm': false,
    }, {
      'team': {'id': 'subject', 'name': 'Предмет', 'groupCode': '',
        'teacher': '', 'icon': '', 'kind': 'subject'},
      'title': 'Предмет', 'lastAuthor': 'Другой автор',
      'lastMsgPreview': 'Карточка тем', 'chatId': 'subject-chat',
      'unread': 0, 'pinned': false, 'muted': false, 'isDm': false,
    }, {
      'team': {'id': 'legacy', 'name': 'Старое имя', 'groupCode': '',
        'teacher': '', 'icon': ''},
      'title': 'Старое имя', 'lastAuthor': 'Старый автор',
      'lastMsgPreview': 'Старый текст', 'chatId': 'legacy-chat',
      'unread': 0, 'pinned': false, 'muted': false, 'isDm': false,
    }, {
      'team': {'id': '', 'name': 'Друг', 'groupCode': '', 'teacher': '', 'icon': ''},
      'title': 'Друг', 'lastMsgPreview': 'Привет', 'chatId': 'dm-chat',
      'peerId': 'peer', 'unread': 0, 'pinned': false, 'muted': false, 'isDm': true,
    }]));
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope,
      child: const MyChatsScreen(enableRealtime: false))));
    expect(find.text('Чат группы'), findsOneWidget);
    expect(find.text('Карточка тем'), findsOneWidget,
        reason: 'ordinary user text must not be suppressed by its wording');
    expect(find.text('Автор'), findsNothing);
    expect(find.text('Чат'), findsOneWidget);
    expect(find.text('Старое имя'), findsNothing);
    expect(find.text('Старый текст'), findsNothing);
    expect(find.text('Друг'), findsOneWidget);
    expect(find.text('Привет'), findsOneWidget);
    cardResponse.complete(http.Response('[]', 200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    await events.close();
  });

  testWidgets('live action preview appears only after an exact available result', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = Supabase.instance.client.auth.currentSession;
    final scope = AuthSessionScope(
        currentSession: () => Supabase.instance.client.auth.currentSession,
        authEvents: events.stream);
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope,
      child: const MyChatsScreen(enableRealtime: false))));
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    for (var i = 0; i < 10 && !cardRequested.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cardRequested.isCompleted, isTrue);
    expect(find.text('Карточка тем'), findsNothing);
    cardResponse.complete(http.Response(jsonEncode([{
      'kind': 'topic_selection', 'entity_id': entity,
      'card_message_id': message, 'available': true, 'status': 'open',
    }]), 200, headers: {'content-type': 'application/json'}));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Карточка тем'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('late legacy cache cannot cross a route boundary', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = Supabase.instance.client.auth.currentSession;
    final scope = AuthSessionScope(
        currentSession: () => Supabase.instance.client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final pending = Completer<String?>();
    final cache = _ThrowingPrewarmCache(scope);
    Widget screen({bool scoped = false}) => MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope,
      child: MyChatsScreen(key: const ValueKey('same'), enableRealtime: false,
        readSummaryCache: (_) => pending.future,
        cachedStore: scoped ? cache : null)));
    await tester.pumpWidget(screen());
    await tester.pump();
    await tester.pumpWidget(screen(scoped: true));
    pending.complete(jsonEncode([{
      'team': {'id': 'team', 'name': 'Старый', 'teacher': '', 'groupCode': '', 'icon': ''},
      'title': 'Старый', 'isDm': false,
    }]));
    await tester.pump();
    expect(find.text('Старый'), findsNothing);
    expect(find.text('Чат'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('late legacy cache cannot replace a newer server result', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = Supabase.instance.client.auth.currentSession;
    final scope = AuthSessionScope(
        currentSession: () => Supabase.instance.client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final pending = Completer<String?>();
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(
      createScope: () => scope,
      child: MyChatsScreen(enableRealtime: false, readSummaryCache: (_) => pending.future))));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 10 && !cardRequested.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Тестовый чат'), findsOneWidget);
    pending.complete(jsonEncode([{
      'team': {'id': 'old', 'name': 'Старый', 'teacher': '', 'groupCode': '', 'icon': '', 'kind': 'subject'},
      'title': 'Старый', 'isDm': false,
    }]));
    await tester.pump();
    expect(find.text('Старый'), findsNothing);
    expect(find.text('Тестовый чат'), findsOneWidget);
    cardResponse.complete(http.Response('[]', 200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 9));
    await events.close();
  });

  testWidgets('optional local prewarm failure cannot break online list', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = Supabase.instance.client.auth.currentSession;
    final scope = AuthSessionScope(currentSession: () => Supabase.instance.client.auth.currentSession,
        authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final cache = _ThrowingPrewarmCache(scope);
    ProjectChatServerCache.qaInstance = cache;
    var showList = false;
    late StateSetter update;
    late SessionCapabilities caps;
    await tester.pumpWidget(MaterialApp(home: AuthSessionScopeHost(createScope: () => scope,
      child: SessionCapabilitiesHost(source: scope, child: StatefulBuilder(builder: (context, set) {
        update = set;
        caps = SessionCapabilitiesHost.maybeRead(context)!;
        return showList ? const MyChatsScreen(enableRealtime: false) : const Text('setup');
      })))));
    expect(caps.grant(SessionCapabilityMode.online, caps.beginAuthorization(scope.capture()!)!), isTrue);
    update(() => showList = true);
    for (var i = 0; i < 50 && !cache.called.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    expect(cache.called.isCompleted, isTrue);
    await tester.pump();
    expect(find.text('Тестовый чат'), findsOneWidget);
    expect(tester.takeException(), isNull);
    cardResponse.complete(http.Response('[]', 200));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    ProjectChatServerCache.qaInstance = null;
    await events.close();
  }, skip: !const bool.fromEnvironment('QA_LOCAL_IMAGE_PREWARM'));

  for (final stale in [false, true]) {
    testWidgets(
        'summary verification is ${stale ? 'ignored after ABA' : 'hidden without persisting status'}',
        (tester) async {
      final events = StreamController<AuthState>.broadcast(sync: true);
      final session = Supabase.instance.client.auth.currentSession;
      final scope = AuthSessionScope(
          currentSession: () => Supabase.instance.client.auth.currentSession,
          authEvents: events.stream);
      addTearDown(events.close);
      await tester.pumpWidget(MaterialApp(
          home: AuthSessionScopeHost(
              createScope: () => scope,
              child: const MyChatsScreen(enableRealtime: false))));
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      for (var i = 0; i < 10 && !cardRequested.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(cardRequested.isCompleted, isTrue);
      expect(find.text('Карточка тем'), findsNothing);
      if (stale) {
        events.add(const AuthState(AuthChangeEvent.signedOut, null));
        events.add(AuthState(AuthChangeEvent.signedIn, session));
      }
      cardResponse.complete(http.Response(
          jsonEncode([
            {
              'kind': 'topic_selection',
              'entity_id': entity,
              'card_message_id': message,
              'available': true,
              'status': 'cancelled',
            }
          ]),
          200,
          headers: {'content-type': 'application/json'}));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Карточка недоступна'), findsNothing);
      expect(find.text('Карточка тем'), findsNothing);
      expect(find.text('Автор'), findsNothing);
      expect(find.text('Тестовый чат'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('my_chats_cache_v2_owner') ?? '';
      expect(cached, contains('Карточка тем'));
      expect(cached, isNot(contains('Карточка недоступна')));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
