import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/forward_group_bubble.dart';
import 'package:student_ui/student_ui.dart';

String nestedForward(int level) => '__FG__:${jsonEncode({
          'fg': 1,
          'caption': 'Подпись $level',
          'items': [
            {
              'id': 'source-$level',
              'aid': '',
              'a': 'Очень длинное имя автора пересылки номер $level',
              'at': '2026-10-31T08:00:00Z',
              'x': level > 0
                  ? nestedForward(level - 1)
                  : 'Полный текст исходного сообщения без потери содержимого.',
              'f': level == 0
                  ? [
                      {
                        'name': 'Длинное название расчётной записки.pdf',
                        'mime': 'application/pdf',
                        'size': 1024
                      }
                    ]
                  : [],
            }
          ]
        })}';

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets('nested forward remains readable at $size dark=$dark',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var retries = 0;
        var reactions = 0;
        final message = Message(
            id: 'message',
            chatId: 'chat',
            authorId: 'author',
            authorLogin: 'login',
            authorName: 'Автор',
            text: nestedForward(2),
            at: DateTime(2026, 10, 31),
            deliveryStatus: MessageDeliveryStatus.failed);
        await tester.pumpWidget(MaterialApp(
            theme: ProductTheme.build(
                brightness: dark ? Brightness.dark : Brightness.light),
            home: MediaQuery(
                data: MediaQueryData(
                    size: size, textScaler: TextScaler.linear(1.5)),
                child: Scaffold(
                    body: SingleChildScrollView(
                        child: Align(
                            alignment: Alignment.topLeft,
                            child: ForwardGroupBubble(
                                message: message,
                                time: '11:00',
                                isMe: dark,
                                selected: dark,
                                idToFile: const {},
                                onRetryFailed: () => retries++,
                                onReact: () => reactions++,
                                reactions: const {'👍': 2})))))));
        await tester.pumpAndSettle();
        final body = find
            .text('Полный текст исходного сообщения без потери содержимого.');
        expect(body, findsOneWidget);
        expect(tester.getSize(body).width, greaterThan(130));
        expect(find.textContaining('31.10.2026'), findsWidgets);
        expect(find.text('Подпись 0'), findsOneWidget);
        expect(find.text('Подпись 1'), findsOneWidget);
        expect(find.text('Подпись 2'), findsOneWidget);
        expect(find.text('Длинное название расчётной записки.pdf'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Не отправлено · Повторить'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Не отправлено · Повторить'));
        await tester.ensureVisible(find.text('👍 2'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('👍 2'));
        expect(retries, 1);
        expect(reactions, 1);
        final reaction =
            tester.getSize(find.byKey(const ValueKey('forward-reaction-👍')));
        expect(reaction.width, inInclusiveRange(48, 120));
        expect(reaction.height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('deep forward never displays serialized payload', (tester) async {
    final message = Message(
        id: 'deep',
        chatId: 'chat',
        authorId: 'author',
        authorLogin: '',
        authorName: 'Автор',
        text: nestedForward(5),
        at: DateTime.utc(2026));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ForwardGroupBubble(
                    message: message,
                    time: '11:00',
                    isMe: false,
                    idToFile: const {})))));
    expect(find.textContaining('__FG__:'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('malformed nested forward does not hang or show its payload',
      (tester) async {
    final message = Message(
        id: 'bad',
        chatId: 'chat',
        authorId: 'author',
        authorLogin: '',
        authorName: 'Автор',
        text: '__FG__:${jsonEncode({
              'fg': 1,
              'items': [
                {'a': 'Автор', 'x': '__FG__:{}'}
              ]
            })}',
        at: DateTime.utc(2026));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ForwardGroupBubble(
                message: message,
                time: '11:00',
                isMe: false,
                idToFile: const {}))));
    expect(find.textContaining('__FG__:'), findsNothing);
    expect(find.text('Пересланное сообщение'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('nested forward with invalid items shape stays readable', (tester) async {
    final message = Message(id: 'bad-items', chatId: 'chat', authorId: 'author', authorLogin: '', authorName: 'Автор', text: '__FG__:${jsonEncode({'fg': 1, 'items': [{'a': 'Автор', 'x': '__FG__:{"fg":1,"items":[1]}'}]})}', at: DateTime.utc(2026));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ForwardGroupBubble(message: message, time: '11:00', isMe: false, idToFile: const {}))));
    expect(find.textContaining('__FG__:'), findsNothing);
    expect(tester.takeException(), isNull);
  });

}
