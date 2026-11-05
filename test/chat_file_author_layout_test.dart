import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/file_message_bubble.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final showAuthor in [true, false]) {
      testWidgets('file author visibility $brightness $showAuthor',
          (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final file = ChatFile(
            id: 'f',
            chatId: 'c',
            messageId: 'm',
            fileName: 'very-long-name-of-a-course-document.pdf',
            fileKey: 'f',
            fileUrl: '',
            fileType: 'application/pdf',
            fileSize: 1234,
            uploadedBy: 'u',
            uploadedAt: DateTime.utc(2026));
        await tester.pumpWidget(MaterialApp(
            theme: ProductTheme.build(brightness: brightness),
            home: MediaQuery(
                data: const MediaQueryData(
                    size: Size(320, 568), textScaler: TextScaler.linear(1.5)),
                child: Scaffold(
                    body: FileMessageBubble(
                        file: file,
                        isMe: false,
                        time: '12:00',
                        authorName: 'Проверка автора',
                        showAuthorLine: showAuthor,
                        showAvatar: false)))));
        expect(find.text('Проверка автора'),
            showAuthor ? findsOneWidget : findsNothing);
        expect(find.text('very-long-name-of-a-course-document.pdf'),
            findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
