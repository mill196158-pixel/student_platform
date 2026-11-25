import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/profile_avatar.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

abstract class _ScopedStore implements ProjectChatServerCache {
  _ScopedStore(this.scope, SessionCapabilities caps)
      : owner = scope.capture()!, permit = caps.capture(SessionCapability.cachedRead)!;
  @override
  final AuthSessionScope scope;
  final AuthOperationScope owner;
  final CapabilityPermit permit;
  bool canRead(SessionCapabilities caps) =>
      caps.mode == SessionCapabilityMode.cacheOnly && caps.owns(permit, owner);

  // These in-memory message fixtures have no SQLite files or history leases.
  @override
  OfflineSessionBinding? Function() get currentBinding => () => null;
  @override
  Future<ChatHistoryRouteLease?> acquireHistoryRouteLease(String chat) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store extends _ScopedStore {
  _Store(this.completer, super.scope, super.caps);
  final Completer<List<Message>?> completer;
  var reads = 0;
  @override
  Future<List<Message>?> read(String chatId, SessionCapabilities caps) async {
    if (chatId != 'chat' || !canRead(caps)) return null;
    reads++;
    return completer.future;
  }
}

class _SummaryStore extends _ScopedStore {
  _SummaryStore(this.kind, super.scope, super.caps);
  final String? kind;
  @override
  Future<List<Map<String, dynamic>>?> readSummaries(
          SessionCapabilities caps) async => !canRead(caps) ? null :
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
      chatId != 'chat' || !canRead(caps) ? null :
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
}

void main() {
  testWidgets('team cache uses local messages and immediately hides on revoke',
      (tester) async {
    await initializeDateFormatting('ru');
    const savedFiles = '{"chat":[{"name":"draft.pdf","path":"local"}]}';
    SharedPreferences.setMockInitialValues({'global_draft_texts': '{"chat":"сохранённый черновик"}',
      'global_draft_files': savedFiles});
    final session = fakeSession('owner');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!);
    final completer = Completer<List<Message>?>();
    final store = _Store(completer, scope, caps);
    await tester.pumpWidget(MaterialApp(
        home: TeamDetailsScreen(
            team: const Team(
                id: 't',
                name: 'Команда',
                teacher: '',
                groupCode: '',
                icon: 'https://example.invalid/network-avatar.png'),
            cachedStore: store,
            cachedCapabilities: caps,
            cachedChatId: 'chat')));
    await tester.pump();
    expect(store.reads, 1);
    expect(find.text('Открываем сохранённые сообщения…'), findsOneWidget);
    completer.complete([
      Message(
          id: 'm',
          chatId: 'chat',
          authorId: 'peer',
          authorLogin: '',
          authorName: 'Участник',
          text: 'Локальное сообщение',
          at: DateTime(2026)),
      Message(id: 'a', chatId: 'chat', authorId: 'peer', authorLogin: '',
          authorName: 'Участник', text: 'Секретный заголовок',
          type: MessageType.assignmentPublished, at: DateTime(2026)),
      Message.fromJson({'id': 'serialized', 'chat_id': 'chat',
        'author_id': 'peer', 'created_at': '2026-01-01T00:00:00Z',
        'content': {'card': 'assignment',
          'assignment_id': '33333333-3333-4333-8333-333333333333'}})
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('Локальное сообщение'), findsOneWidget);
    expect(find.text('Задание недоступно офлайн'), findsNothing);
    expect(find.text('Карточка недоступна'), findsNothing);
    expect(find.text('Секретный заголовок'), findsNothing);
    expect(tester.widget<ProfileAvatar>(find.byType(ProfileAvatar).first).imageUrl, '');
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect((await SharedPreferences.getInstance()).getString('global_draft_texts'),
        '{"chat":"сохранённый черновик"}');
    expect((await SharedPreferences.getInstance()).getString('global_draft_files'), savedFiles);
    expect(
        find.byWidgetPredicate(
            (widget) => widget is Image && widget.image is NetworkImage),
        findsNothing);
    caps.block();
    await tester.pump();
    expect(find.text('Локальное сообщение'), findsNothing);
    expect(find.text('Сохранённый чат недоступен.'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('global_draft_texts'),
        '{"chat":"сохранённый черновик"}');
    expect((await SharedPreferences.getInstance()).getString('global_draft_files'), savedFiles);
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
              cachedStore: _SummaryStore(kind, scope, caps), cachedCapabilities: caps)));
      await tester.pumpAndSettle();
      final title = kind == 'group_space' ? 'Чат группы' : 'Название чата';
      expect(find.text(title), findsOneWidget);
      await tester.tap(find.text(title));
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
    final store = _Store(completer, scope, caps);
    await tester.pumpWidget(MaterialApp(
        home: TeamDetailsScreen(
            team: const Team(id: 't', name: 'Команда', teacher: '',
                groupCode: '', icon: ''),
            cachedStore: store,
            cachedCapabilities: caps,
            cachedChatId: 'chat')));
    await tester.pump();
    expect(store.reads, 1);
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
