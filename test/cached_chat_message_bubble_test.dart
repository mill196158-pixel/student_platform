import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_message_bubble.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

class _Service implements DmChatService {
  @override
  String get currentUserId => 'owner';
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets(
      'local bubble renders author, time, reactions and forward without network',
      (tester) async {
    final service = _Service();
    final at = DateTime(2026, 11, 6, 10, 42);
    final forward = ForwardPayload(fromChatId: 'chat', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'Автор',
          at: at,
          text: 'Текст пересылки',
          files: [
            const ForwardFileRef(
                url: 'https://untrusted.invalid/private',
                name: 'file.pdf',
                type: 'application/pdf',
                size: 42)
          ])
    ]);
    final message = Message(
        id: 'id',
        chatId: 'chat',
        authorId: 'other',
        authorLogin: 'other',
        authorName: 'Собеседник',
        text: forward.encodeForText(),
        at: at,
        reactions: const {'❤️': 2});
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CachedChatMessageBubble(
                message: message, service: service, showAuthor: true))));
    expect(find.text('Собеседник'), findsOneWidget);
    expect(find.textContaining('Автор: Текст пересылки'), findsOneWidget);
    expect(find.textContaining('file.pdf'), findsOneWidget);
    expect(find.text('❤️ 2'), findsOneWidget);
    expect(find.textContaining('10:42'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage),
        findsNothing);
    expect(find.textContaining('__FG__:'), findsNothing);
  });
}
