import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

class _Store implements ProjectChatServerCache {
  _Store(this.completer);
  final Completer<List<Message>?> completer;
  @override
  Future<List<Message>?> read(String chatId, SessionCapabilities caps) =>
      completer.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SummaryStore implements ProjectChatServerCache {
  _SummaryStore(this.kind);
  final String? kind;
  @override
  Future<List<Map<String, dynamic>>?> readSummaries(
          SessionCapabilities caps) async =>
      [
        {
          'team': {
            'id': 'team',
            'name': 'Предмет',
            'teacher': '',
            'groupCode': 'Группа',
            'icon': '',
            if (kind != null) 'kind': kind
          },
          'title': 'Название чата',
          'chatId': 'chat',
          'isDm': false,
          'unread': 0,
          'pinned': false,
          'muted': false
        }
      ];
  @override
  Future<List<Message>?> read(String chatId, SessionCapabilities caps) async =>
      [
        Message(
            id: 'm',
            chatId: chatId,
            authorId: 'peer',
            authorLogin: '',
            authorName: 'Участник',
            text: 'Текст группы',
            at: DateTime(2026))
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('team cache uses local messages and immediately hides on revoke',
      (tester) async {
    await initializeDateFormatting('ru');
    final session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!);
    final completer = Completer<List<Message>?>();
    await tester.pumpWidget(MaterialApp(
        home: TeamDetailsScreen(
            team: const Team(
                id: 't',
                name: 'Команда',
                teacher: '',
                groupCode: '',
                icon: 'https://example.invalid/network-avatar.png'),
            cachedStore: _Store(completer),
            cachedCapabilities: caps,
            cachedChatId: 'chat')));
    await tester.pump();
    expect(find.text('Открываем сохранённые сообщения…'), findsOneWidget);
    completer.complete([
      Message(
          id: 'm',
          chatId: 'chat',
          authorId: 'peer',
          authorLogin: '',
          authorName: 'Участник',
          text: 'Локальное сообщение',
          at: DateTime(2026))
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Локальное сообщение'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Image && widget.image is NetworkImage),
        findsNothing);
    caps.block();
    await tester.pump();
    expect(find.text('Локальное сообщение'), findsNothing);
    expect(find.text('Сохранённый чат недоступен.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
  });

  for (final kind in <String?>['group_space', 'subject', null]) {
    testWidgets('scoped team route handles kind $kind without guessing',
        (tester) async {
      await initializeDateFormatting('ru');
      final session = fakeSession('owner');
      final events = StreamController<AuthState>.broadcast(sync: true);
      final scope = AuthSessionScope(
          currentSession: () => session, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, session));
      final caps = SessionCapabilities(scope);
      caps.grant(SessionCapabilityMode.cacheOnly,
          caps.beginAuthorization(scope.capture()!)!);
      await tester.pumpWidget(MaterialApp(
          home: MyChatsScreen(
              cachedStore: _SummaryStore(kind), cachedCapabilities: caps)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Название чата'));
      await tester.pumpAndSettle();
      expect(find.text('Текст группы'), findsOneWidget);
      expect(find.text('Общий чат группы'),
          kind == 'group_space' ? findsOneWidget : findsNothing);
      caps.block();
      await tester.pump();
      expect(find.text('Текст группы'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      caps.dispose();
      scope.dispose();
      await events.close();
    });
  }

  testWidgets('late team snapshot cannot paint after capability revoke',
      (tester) async {
    await initializeDateFormatting('ru');
    final session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!);
    final completer = Completer<List<Message>?>();
    await tester.pumpWidget(MaterialApp(
        home: TeamDetailsScreen(
            team: const Team(id: 't', name: 'Команда', teacher: '',
                groupCode: '', icon: ''),
            cachedStore: _Store(completer),
            cachedCapabilities: caps,
            cachedChatId: 'chat')));
    caps.block();
    completer.complete([Message(id: 'm', chatId: 'chat', authorId: 'peer',
        authorLogin: '', authorName: '', text: 'Поздние данные', at: DateTime(2026))]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Поздние данные'), findsNothing);
    expect(find.text('Сохранённый чат недоступен.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
}
