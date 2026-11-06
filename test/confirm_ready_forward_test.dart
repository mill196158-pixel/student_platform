import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/forward/confirm_ready_forward.dart';

void main() {
  for (final accept in [false, true]) {
    testWidgets('review displays every item and records ${accept ? 'approval' : 'deferral'}',
        (tester) async {
      bool? result;
      final nested = ForwardPayload(fromChatId: 'nested', items: [
        ForwardItem(messageId: '3', authorId: 'c', authorName: 'Вложенный автор',
            at: DateTime.utc(2026), text: 'Вложенный текст', files: [
              ForwardFileRef(id: 'n', url: 'https://example.test/n',
                  name: 'вложенный.pdf', type: 'application/pdf', size: 1),
            ]),
      ]);
      final payload = ForwardPayload(fromChatId: 'source', caption: 'Подпись', items: [
        ForwardItem(messageId: '1', authorId: 'a', authorName: 'Автор',
            at: DateTime.utc(2026), text: 'Первое', files: const []),
        ForwardItem(messageId: '2', authorId: 'b', authorName: 'Другой',
            at: DateTime.utc(2026), text: 'Второе', files: [
              ForwardFileRef(id: 'f', url: 'https://example.test/f',
                  name: 'документ.pdf', type: 'application/pdf', size: 1),
            ]),
        ForwardItem(messageId: '4', authorId: 'd', authorName: 'Пересылка',
            at: DateTime.utc(2026), text: nested.encodeForText(), files: const []),
      ]);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
          TextButton(onPressed: () async { result = await confirmReadyForward(context, payload); },
              child: const Text('Открыть'))))));
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.text('Первое'), findsOneWidget);
      expect(find.text('Второе'), findsOneWidget);
      expect(find.text('Вложение: документ.pdf'), findsOneWidget);
      expect(find.text('Вложенный текст'), findsOneWidget);
      expect(find.text('Вложение: вложенный.pdf'), findsOneWidget);
      await tester.tap(find.text(accept ? 'Продолжить' : 'Позже'));
      await tester.pumpAndSettle();
      expect(result, accept);
    });
  }
}
