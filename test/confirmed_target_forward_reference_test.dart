import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_message_bubble.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';

class _Service implements DmChatService {
  @override
  String get currentUserId => 'owner';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('confirmed target attachment does not require source snapshot', (tester) async {
    const key = 'chats/target/copy.pdf';
    Map<String, Object?> row(Object? deleted) => {
      'id': 'target-message', 'chat_id': 'target-chat', 'author_id': 'owner',
      'at': '2026-01-01T00:00:00Z', 'text': '', 'type': 'forward',
      'has_more': false,
      'content': jsonEncode({'from_chat_id': 'unavailable-source', 'items': [{
        'id': 'source-message', 'author_id': 'author', 'author_name': 'Автор',
        'created_at': '2026-01-01T00:00:00Z', 'text': 'Текст',
        'attachments': [{'id': 'target-file', 'url': key, 'name': 'copy.pdf'}],
      }]}),
      'attachments': [{
        'id': 'target-file', 'chat_id': 'target-chat', 'message_id': 'target-message',
        'file_name': 'copy.pdf', 'file_key': key, 'file_url': key,
        'file_type': 'application/pdf', 'file_size': 7, 'is_deleted': deleted,
      }],
    };
    Future<void> show(Object? deleted) async {
      final page = DmApi.parseConfirmedMessagesPage([row(deleted)], 'target-chat', limit: 50);
      final restored = Message.fromJson(page.messages.single.toJson());
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: CachedChatMessageBubble(
        message: restored, service: _Service(), showAuthor: false,
        debugForwardAttachmentBuilder: (file) => Text('target:${file.id}'),
      ))));
    }
    await show(false);
    expect(find.text('target:target-file'), findsOneWidget);
    await show(null);
    expect(find.text('target:target-file'), findsNothing);
    expect(find.textContaining('copy.pdf'), findsWidgets);
  });
}
