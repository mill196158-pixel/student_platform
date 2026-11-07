import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/widgets/team_avatar.dart';
import 'package:student_platform/src/ui/navigation/cached_team_chat_directory.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Store implements ProjectChatServerCache {
  _Store(this.scope);
  @override
  final AuthSessionScope scope;
  @override
  OfflineSessionBinding? Function() get currentBinding => () => null;
  final wait = Completer<List<Message>?>();
  int reads = 0;
  @override
  Future<List<Map<String, dynamic>>?> readSummaries(
          SessionCapabilities caps) async =>
      [
        {
          'isDm': false,
          'chatId': 'chat',
          'team': {
            'id': 'team',
            'name': 'Предмет',
            'teacher': '',
            'groupCode': '',
            'icon': '',
            'kind': 'subject'
          }
        }
      ];
  @override
  Future<List<Message>?> read(String chat, SessionCapabilities caps) async {
    reads++;
    return reads == 1 ? <Message>[] : wait.future;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _SummaryStore implements ProjectChatServerCache {
  _SummaryStore(this.rows, this.histories, this.scope);
  @override
  final AuthSessionScope scope;
  @override
  OfflineSessionBinding? Function() get currentBinding => () => null;
  final List<Map<String, dynamic>> rows;
  final Map<String, List<Message>?> histories;
  @override
  Future<List<Map<String, dynamic>>?> readSummaries(SessionCapabilities caps) async => rows;
  @override
  Future<List<Message>?> read(String chat, SessionCapabilities caps) async => histories[chat];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  for (final subjectsOnly in [true, false]) {
    testWidgets('directory header stays below top system inset: $subjectsOnly',
        (tester) async {
      final session = fakeSession('a');
      final events = StreamController<AuthState>.broadcast(sync: true);
      final scope = AuthSessionScope(
          currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      final caps = SessionCapabilities(scope);
      expect(caps.grant(SessionCapabilityMode.cacheOnly,
          caps.beginAuthorization(scope.capture()!)!), isTrue);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(800, 600),
              padding: EdgeInsets.only(top: 32),
              viewPadding: EdgeInsets.only(top: 32)),
          child: CachedTeamChatDirectory(
              store: _Store(scope), capabilities: caps, subjectsOnly: subjectsOnly),
        ),
      ));
      await tester.pumpAndSettle();
      final title = find.text(subjectsOnly
          ? 'База' : 'Команды');
      expect(title, findsOneWidget);
      expect(tester.getTopLeft(title).dy, greaterThanOrEqualTo(32));
      await tester.pumpWidget(const SizedBox());
      caps.dispose();
      scope.dispose();
      await events.close();
    });
  }
  testWidgets('replacing store closes already opened scoped route',
      (tester) async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    final first = _Store(scope), second = _Store(scope);
    first.wait.complete(<Message>[]);
    await tester.pumpWidget(MaterialApp(
        home: CachedTeamChatDirectory(
            store: first, capabilities: caps, subjectsOnly: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Предмет'));
    await tester.pumpAndSettle();
    expect(find.byType(TeamDetailsScreen), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
        home: CachedTeamChatDirectory(
            store: second, capabilities: caps, subjectsOnly: true)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TeamDetailsScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
  testWidgets('delayed tap cannot open a stale store or mode', (tester) async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    final first = _Store(scope), second = _Store(scope);
    await tester.pumpWidget(MaterialApp(
        home: CachedTeamChatDirectory(
            store: first, capabilities: caps, subjectsOnly: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Предмет'));
    await tester.pump();
    await tester.pumpWidget(MaterialApp(
        home: CachedTeamChatDirectory(
            store: second, capabilities: caps, subjectsOnly: false)));
    first.wait.complete(<Message>[]);
    await tester.pumpAndSettle();
    expect(find.byType(TeamDetailsScreen), findsNothing);
    expect(find.text('Команды'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
  testWidgets('offline lists preserve known types and keep unsaved histories visible', (tester) async {
    var session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    Map<String, dynamic> row(String id, String name, String kind) => {
      'isDm': false, 'chatId': 'chat-$id', 'team': {'id': id, 'name': name,
      'teacher': 'Преподаватель', 'groupCode': 'Группа', 'icon': '', 'kind': kind}};
    final store = _SummaryStore([row('s1', 'Первый предмет', 'subject'),
      row('g', 'Пространство группы', 'group_space'), row('s2', 'Второй предмет', 'subject')],
      {'chat-s1': <Message>[], 'chat-g': <Message>[], 'chat-s2': null}, scope);
    (store.rows[1]['team'] as Map)['groupCode'] = '1-См(ВВ)-2';
    (store.rows[1]['team'] as Map)['icon'] = 'https://example.invalid/avatar.png';
    await tester.pumpWidget(MaterialApp(home: CachedTeamChatDirectory(
      store: store, capabilities: caps, subjectsOnly: false)));
    await tester.pumpAndSettle();
    expect(find.text('Команды'), findsOneWidget);
    expect(find.text('Первый предмет'), findsOneWidget);
    expect(find.text('Второй предмет'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Чат группы')).dy,
      lessThan(tester.getTopLeft(find.text('Первый предмет')).dy));
    expect(tester.getTopLeft(find.text('Первый предмет')).dy,
      lessThan(tester.getTopLeft(find.text('Второй предмет')).dy));
    expect(find.text('История не сохранена на устройстве'), findsOneWidget);
    expect(find.text('1-См(ВВ)-2 · общий чат'), findsOneWidget);
    final avatar = tester.widget<TeamAvatar>(find.descendant(
      of: find.byKey(const ValueKey('open-learning-group-chat')),
      matching: find.byType(TeamAvatar)));
    expect(avatar.name, 'Чат группы');
    expect(avatar.icon, 'groups', reason: 'offline tile does not load the saved remote avatar');
    await tester.tap(find.text('Второй предмет'));
    await tester.pump();
    expect(find.text('История этого чата не сохранена на устройстве.'), findsOneWidget);
    expect(find.text('Второй предмет'), findsOneWidget);
    expect(find.byType(TeamDetailsScreen), findsNothing);
    await tester.tap(find.text('Чат группы'));
    await tester.pumpAndSettle();
    final details = tester.widget<TeamDetailsScreen>(find.byType(TeamDetailsScreen));
    expect(details.team.id, 'g');
    expect(details.team.name, 'Пространство группы');
    expect(details.team.icon, 'https://example.invalid/avatar.png');
    expect(details.cachedChatId, 'chat-g');
    expect(identical(details.cachedCapabilities, caps), isTrue);
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    expect(find.text('Первый предмет'), findsNothing);
    expect(find.text('Второй предмет'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    caps.dispose(); scope.dispose(); await events.close();
  });

}
