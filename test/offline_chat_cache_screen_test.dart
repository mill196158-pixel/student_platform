import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/data/offline_chat_cache_reader.dart';
import 'package:student_platform/src/ui/chats/offline_chat_cache_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

void main() {
  testWidgets('late account results cannot replace the new account',
      (tester) async {
    final a = Completer<String?>();
    final reader = OfflineChatCacheReader(
        readSummaries: (uid) => uid == 'a'
            ? a.future
            : Future.value('[{"chatId":"b-chat","title":"Чат Б"}]'));
    Widget screen(String uid) => MaterialApp(
          home: OfflineChatCacheScreen(
              userId: uid, reader: reader, onRetryConnection: () {}),
        );
    await tester.pumpWidget(screen('a'));
    await tester.pumpWidget(screen('b'));
    await tester.pump();
    expect(find.text('Чат Б'), findsOneWidget);
    a.complete('[{"chatId":"a-chat","title":"Чат А"}]');
    await tester.pump();
    expect(find.text('Чат Б'), findsOneWidget);
    expect(find.text('Чат А'), findsNothing);
  });

  testWidgets(
      'shows local messages without raw forwarded payload or remote images',
      (tester) async {
    final now = DateTime.utc(2026);
    final reader = OfflineChatCacheReader(
      readSummaries: (_) async => '[{"chatId":"one","title":"Чат"}]',
      readMessages: (_, __) async => ChatCacheSnapshot(found: true, messages: [
        Message(
            id: '1',
            chatId: 'one',
            authorId: 'a',
            authorLogin: 'a',
            authorName: 'Автор',
            text: '__FG__:{broken',
            at: now,
            authorAvatarUrl: 'https://example.invalid/avatar'),
      ]),
    );
    await tester.pumpWidget(MaterialApp(
        home: OfflineChatCacheScreen(
      userId: 'a',
      reader: reader,
      onRetryConnection: () {},
    )));
    await tester.pump();
    await tester.tap(find.text('Чат'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('__FG__'), findsNothing);
    expect(find.text('Пересланное сообщение'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
  testWidgets('late messages from a closed chat do not appear in another',
      (tester) async {
    final first = Completer<ChatCacheSnapshot>();
    var reads = 0;
    final reader = OfflineChatCacheReader(
      readSummaries: (_) async =>
          '[{"chatId":"one","title":"Первый"},{"chatId":"two","title":"Второй"}]',
      readMessages: (id, _) {
        reads++;
        return id == 'one'
            ? first.future
            : Future.value(const ChatCacheSnapshot(found: true, messages: []));
      },
    );
    await tester.pumpWidget(MaterialApp(
        home: OfflineChatCacheScreen(
      userId: 'a',
      reader: reader,
      onRetryConnection: () {},
    )));
    await tester.pump();
    await tester.tap(find.text('Первый'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Второй'));
    await tester.pump();
    await tester.pump();
    first.complete(ChatCacheSnapshot(found: true, messages: [
      Message(
          id: '1',
          chatId: 'one',
          authorId: 'a',
          authorLogin: 'a',
          authorName: 'Первый автор',
          text: 'Старое',
          at: DateTime.utc(2026)),
    ]));
    await tester.pump();
    expect(find.text('Первый автор'), findsNothing);
    expect(find.text('Сохранённых сообщений нет.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(reads, 2);
  });

  testWidgets('a synchronous cache error shows a local error state',
      (tester) async {
    final reader = OfflineChatCacheReader(
      readSummaries: (_) async => '[{"chatId":"one","title":"Чат"}]',
      readMessages: (_, __) => throw StateError('cache unavailable'),
    );
    await tester.pumpWidget(MaterialApp(
        home: OfflineChatCacheScreen(
      userId: 'a',
      reader: reader,
      onRetryConnection: () {},
    )));
    await tester.pump();
    await tester.tap(find.text('Чат'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Не удалось прочитать сообщения.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
