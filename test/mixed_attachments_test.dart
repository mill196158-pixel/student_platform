import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/attachment_widget.dart';
import 'package:student_platform/src/ui/learning/widgets/file_card.dart';

ChatFile file(String name, String mime) => ChatFile(
      id: name,
      chatId: 'fixture',
      messageId: 'message',
      fileName: name,
      fileKey: name,
      fileUrl: 'https://example.invalid/$name',
      fileType: mime,
      fileSize: 32,
      uploadedBy: 'fixture',
      uploadedAt: DateTime.utc(2026),
    );

void main() {
  testWidgets('mixed attachments render each image and document exactly once',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AttachmentWidget(
          files: [
            file('photo.png', 'image/png'),
            file('notes.pdf', 'application/pdf')
          ],
          isMe: true,
          time: '12:00',
        ),
      ),
    ));
    expect(find.byType(AuthorizedFileImage), findsOneWidget);
    expect(find.byType(AppFileCard), findsOneWidget);
    expect(find.text('notes.pdf'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
