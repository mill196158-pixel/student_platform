import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_message_bubble.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';

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

  testWidgets('serialized forward keeps text, verified author and canonical file', (tester) async {
    final now = DateTime.utc(2026, 1, 2);
    final file = ChatFile(id: 'file-id', chatId: 'chat', messageId: 'outer',
      fileName: 'a.pdf', fileKey: 'chats/a', fileUrl: 'https://example.test/chats/a',
      fileType: 'application/pdf', fileSize: 9, uploadedBy: 'a', uploadedAt: now,
      deletionVerified: true);
    final source = Message.fromJson({
      'id': 'outer', 'chat_id': 'chat', 'author_id': 'a',
      'author_name': 'Студент', 'author_login': '', 'author_name_verified': true,
      'created_at': now.toIso8601String(), 'msg_type': 'forward',
      'content': {'from_chat_id': 'chat', 'items': [{
        'id': 'inner', 'author_id': 'b', 'author_name': 'Автор',
        'created_at': now.toIso8601String(), 'text': 'Студент',
        'attachments': [{'id': file.id, 'url': file.fileUrl,
          'name': file.fileName, 'mime': file.fileType, 'size': file.fileSize}]
      }]}, 'attachments': [file.toJson()],
    });
    final restored = Message.fromJson(source.toJson());
    expect(restored.forward!.items.single.attachments.single.url, file.fileUrl);
    expect(restored.forward!.items.single.text, 'Студент');
    expect(restored.authorNameVerified, isTrue);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatMessageBubble(
      message: restored, service: _Service(), showAuthor: true,
      debugForwardAttachmentBuilder: (f) => Text('local:${f.id}')))));
    expect(find.text('local:file-id'), findsOneWidget);
    expect(find.textContaining('Автор: Студент'), findsOneWidget);
    expect(find.text('Студент'), findsOneWidget);

    final unknown = restored.copyWith(authorNameVerified: false);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatMessageBubble(
      message: unknown, service: _Service(), showAuthor: true,
      debugForwardAttachmentBuilder: (f) => Text('local:${f.id}')))));
    expect(find.text('Студент'), findsNothing);
    expect(find.textContaining('Автор: Студент'), findsOneWidget);
  });

  testWidgets('nested forward opens only exact, nondeleted canonical references', (tester) async {
    final at = DateTime.utc(2026, 1, 2);
    final file = ChatFile(id: 'file-id', chatId: 'chat', messageId: 'outer',
      fileName: 'a.pdf', fileKey: 'chats/a', fileUrl: 'https://example.test/chats/a',
      fileType: 'application/pdf', fileSize: 9, uploadedBy: 'a', uploadedAt: at,
      deletionVerified: true);
    final nested = ForwardPayload(fromChatId: 'chat', items: [ForwardItem(
      messageId: 'inner', authorId: 'a', authorName: 'Автор', at: at, text: '',
      files: [ForwardFileRef(id: file.id, url: file.fileUrl, name: file.fileName,
        type: file.fileType, size: file.fileSize)])]);
    final outer = ForwardPayload(fromChatId: 'chat', items: [ForwardItem(
      messageId: 'outer', authorId: 'a', authorName: 'Автор', at: at,
      text: nested.encodeForText(), files: const [])]);
    Message make(ChatFile f) => Message(id: 'm', chatId: 'chat', authorId: 'a',
      authorLogin: 'a', authorName: 'Автор', text: outer.encodeForText(), at: at,
      attachments: [f]);
    Future<void> show(ChatFile f) => tester.pumpWidget(MaterialApp(home: Scaffold(
      body: CachedChatMessageBubble(message: make(f), service: _Service(), showAuthor: false,
        debugForwardAttachmentBuilder: (f) => Text('local:${f.fileUrl}')))));
    await show(file);
    expect(find.text('local:https://example.test/chats/a'), findsOneWidget);
    await show(file.copyWith(fileUrl: 'https://example.test/chats/different'));
    expect(find.text('local:https://example.test/chats/a'), findsNothing);
    expect(find.text('local:https://example.test/chats/different'), findsOneWidget);
    expect(find.textContaining('a.pdf'), findsWidgets);
    await show(file.copyWith(isDeleted: true));
    expect(find.textContaining('local:'), findsNothing);
    // A historical snapshot with an implicit false deletion flag must not
    // promote the forwarded reference to a verified local attachment.
    final oldFile = ChatFile.fromJson({...file.toJson()}..remove('deletion_verified'));
    expect(oldFile.isDeleted, isFalse);
    expect(oldFile.deletionVerified, isFalse);
    await show(oldFile);
    expect(find.textContaining('📎 a.pdf'), findsOneWidget);
    expect(find.textContaining('local:'), findsNothing);
    final ambiguous = make(file).copyWith(attachments: [
      file, file.copyWith(fileUrl: 'https://example.test/chats/other')]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatMessageBubble(
      message: ambiguous, service: _Service(), showAuthor: false,
      debugForwardAttachmentBuilder: (f) => Text('local:${f.fileUrl}')))));
    expect(find.textContaining('📎 a.pdf'), findsOneWidget);
    expect(find.textContaining('local:'), findsNothing);
  });
}
