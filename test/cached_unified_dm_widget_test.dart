import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  setUpAll(() async => initializeDateFormatting('ru'));
  testWidgets('cached DM shows local text then hides it on capability revoke',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    expect(caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!), isTrue);
    final service = DmChatService.cachedOnly(peerId: 'peer', initialChatId: 'chat', capabilities: caps,
      cacheReader: (_, __) async => ChatCacheSnapshot(found: true, messages: [Message(
        id: 'm', chatId: 'chat', authorId: 'a', authorLogin: 'a', authorName: 'A',
        text: 'Сохранённый текст', at: DateTime.utc(2026))]));
    await tester.pumpWidget(MaterialApp(home: UnifiedChatScreen(service: service, title: 'Чат')));
    await tester.pump();
    expect(find.text('Сохранённый текст'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Отправить'), findsNothing);
    caps.block();
    await tester.pump();
    expect(find.text('Сохранённый текст'), findsNothing);
    expect(find.text('Сохранённый чат недоступен.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await service.dispose();
    caps.dispose();
    scope.dispose();
    await events.close();
  });

  testWidgets('missing cache is not presented as an empty conversation', (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    final service = DmChatService.cachedOnly(peerId: 'peer', initialChatId: 'chat', capabilities: caps,
      cacheReader: (_, __) async => ChatCacheSnapshot.notFound);
    await tester.pumpWidget(MaterialApp(home: UnifiedChatScreen(service: service, title: 'Чат')));
    await tester.pump();
    expect(find.text('Сохранённые сообщения недоступны.'), findsOneWidget);
    expect(find.text('Сообщений пока нет'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await service.dispose();
    caps.dispose();
    scope.dispose();
    await events.close();
  });
}
