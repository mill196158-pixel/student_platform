import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://test.invalid',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('get_my_chat_summaries')) {
            return http.Response(
                jsonEncode([
                  {
                    'chat_id': chat,
                    'chat_type': 'team_main',
                    'team_id': chat,
                    'team_name': 'Тестовый чат',
                    'title': 'Тестовый чат',
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
  });
  tearDownAll(() => Supabase.instance.dispose());

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
      expect(find.text('Карточка тем'), findsOneWidget);
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
      expect(find.text('Карточка тем'), stale ? findsOneWidget : findsNothing);
      expect(find.text('Автор'), stale ? findsOneWidget : findsNothing);
      expect(find.text('Тестовый чат'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('my_chats_cache_v2_owner') ?? '';
      expect(cached, contains('Карточка тем'));
      expect(cached, isNot(contains('Карточка недоступна')));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
