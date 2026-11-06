import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Cache implements ProjectChatServerCache {
  int calls = 0;
  @override
  Future<List<Map<String, dynamic>>?> readSummaries(
      SessionCapabilities caps) async {
    calls++;
    return [
      {
        'team': {
          'id': '',
          'name': 'Peer',
          'teacher': '',
          'groupCode': '',
          'icon': ''
        },
        'title': 'Сохранённый чат',
        'chatId': 'chat',
        'isDm': true,
        'peerId': 'peer',
        'unread': 0,
        'pinned': false,
        'muted': false
      },
      for (final entry in [
        ('Группа тем', 'Карточка тем', true),
        ('Группа сбора', 'Карточка сбора', true),
        ('Обычный текст', 'Карточка тем', false),
      ])
        {
          'team': {'id': entry.$1, 'name': entry.$1, 'teacher': '', 'groupCode': '', 'icon': ''},
          'title': entry.$1,
          'chatId': entry.$1,
          'isDm': false,
          'lastAuthor': 'Автор',
          'lastMsgPreview': entry.$2,
          if (entry.$3) 'lastActionCard': true,
          'unread': 0,
          'pinned': false,
          'muted': false,
        }
    ];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets('cached chat list does not use v1 and disappears on revoke',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true),
        session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope), cache = _Cache();
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!);
    await tester.pumpWidget(MaterialApp(
        home: MyChatsScreen(cachedStore: cache, cachedCapabilities: caps)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Сохранённый чат'), findsOneWidget);
    expect(find.text('Группа тем'), findsOneWidget);
    expect(find.text('Группа сбора'), findsOneWidget);
    expect(find.text('Карточка тем'), findsOneWidget);
    expect(find.text('Карточка сбора'), findsNothing);
    expect(find.text('Автор'), findsOneWidget);
    expect(cache.calls, 1);
    expect(find.byTooltip('Ещё'), findsNothing);
    caps.block();
    await tester.pump();
    expect(find.text('Сохранённый чат'), findsNothing);
    expect(find.text('Сохранённые чаты недоступны.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
  testWidgets('switching existing chat-list route cannot re-enable network',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true),
        session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope), cache = _Cache();
    caps.grant(SessionCapabilityMode.cacheOnly,
        caps.beginAuthorization(scope.capture()!)!);
    await tester.pumpWidget(MaterialApp(
        home: MyChatsScreen(
            key: const ValueKey('list'),
            cachedStore: cache,
            cachedCapabilities: caps)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Сохранённый чат'), findsOneWidget);
    await tester.pumpWidget(
        const MaterialApp(home: MyChatsScreen(key: ValueKey('list'))));
    await tester.pump();
    expect(find.text('Сохранённый чат'), findsNothing);
    expect(find.text('Сохранённые чаты недоступны.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    caps.dispose();
    scope.dispose();
    await events.close();
  });
}
