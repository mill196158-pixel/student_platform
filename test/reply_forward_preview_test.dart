import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/core/dm_composer_bar.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';

void main() {
  String forward(String text) => '__FG__:${jsonEncode({
            'fg': 1,
            'from': 'chat',
            'items': [
              {'a': 'Автор', 'x': text, 'f': []}
            ]
          })}';
  Message message(String text) => Message(
      id: 'm',
      chatId: 'c',
      authorId: 'u',
      authorLogin: '',
      authorName: 'Автор',
      text: text,
      at: DateTime.utc(2026));
  test(
      'display preview hides nested and invalid forward payloads without changing original',
      () {
    for (final input in [
      forward('Привет'),
      forward(forward('Привет')),
      '__FG__:broken',
      'Мой комментарий __FG__:broken'
    ]) {
      final m = message(input);
      expect(ChatCardPreview.forPreview(m), isNot(contains('__FG__:')));
      expect(ChatCardPreview.forMessage(m), input);
    }
    expect(ChatCardPreview.forPreview(message(forward(forward('Привет')))),
        'Привет');
    expect(ChatCardPreview.forPreview(message('__FG__:broken')),
        'Пересланное сообщение');
    expect(
        ChatCardPreview.forPreview(message('Обычный текст')), 'Обычный текст');
  });
  for (final group in [true, false]) {
    testWidgets('reply composer hides forward data group=$group',
        (tester) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      var closed = false;
      final reply = message(forward(forward('Проверка ответа')));
      final Widget bar = group
          ? ChatComposerBar(
              controller: controller,
              focusNode: focus,
              replyTo: reply,
              onCloseReply: () => closed = true,
              someoneTyping: false,
              typingNames: const [],
              attachedFiles: const [],
              onSend: () {},
              onPickImage: () async {},
              onOpenEmoji: () {},
              onAttachFile: null,
              onRemoveFile: (_) {},
              onAddFile: (_) {},
              onPinText: (_) {},
              onFind: () async {},
              onPropose: (_, __, ___, ____, _____) async {})
          : DmComposerBar(
              controller: controller,
              focusNode: focus,
              replyTo: reply,
              onCloseReply: () => closed = true,
              someoneTyping: false,
              typingNames: const [],
              attachedFiles: const [],
              onSend: () {},
              onPickImage: () async {},
              onOpenEmoji: () {},
              onAttachFile: null,
              onRemoveFile: (_) {},
              onAddFile: (_) {},
              onPinText: (_) {});
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Align(alignment: Alignment.bottomCenter, child: bar))));
      expect(find.text('Проверка ответа'), findsOneWidget);
      expect(find.textContaining('__FG__:'), findsNothing);
      await tester.tap(find.byIcon(Icons.close).first);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
