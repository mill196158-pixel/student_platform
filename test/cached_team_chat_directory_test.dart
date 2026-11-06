import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/navigation/cached_team_chat_directory.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Store implements ProjectChatServerCache {
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
              store: _Store(), capabilities: caps, subjectsOnly: subjectsOnly),
        ),
      ));
      await tester.pumpAndSettle();
      final title = find.text(subjectsOnly
          ? 'Сохранённые чаты предметов' : 'Сохранённые чаты команд');
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
    final first = _Store(), second = _Store();
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
    final first = _Store(), second = _Store();
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
    expect(find.text('Сохранённые чаты команд'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
}
