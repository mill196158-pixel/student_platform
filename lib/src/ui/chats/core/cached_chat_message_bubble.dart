import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_attachment.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/message_bubble.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';

/// Existing message presentation with no online avatar, actions or file fetch.
class CachedChatMessageBubble extends StatelessWidget {
  const CachedChatMessageBubble(
      {super.key,
      required this.message,
      required this.service,
      required this.showAuthor});
  final Message message;
  final DmChatService service;
  final bool showAuthor;

  @override
  Widget build(BuildContext context) {
    final embedded = ForwardPayload.tryParse(message.text);
    var text = ChatCardPreview.forPreview(message);
    if (embedded != null) {
      final lines = <String>['Пересланные сообщения'];
      if ((embedded.caption ?? '').trim().isNotEmpty) {
        lines.add(ForwardPayload.displayText(embedded.caption!));
      }
      for (final item in embedded.items.take(30)) {
        final body = ForwardPayload.displayText(item.text);
        final author = item.authorName.trim();
        if (body.isNotEmpty)
          lines.add(author.isEmpty ? body : '$author: $body');
        for (final file in item.files.take(10)) {
          lines.add(
              '📎 ${file.name.trim().isEmpty ? 'Вложение' : file.name.trim()}');
        }
      }
      text = lines.join('\n');
    } else if (message.type == MessageType.forward && message.forward != null) {
      final lines = <String>['Пересланные сообщения'];
      for (final item in message.forward!.items.take(30)) {
        final body = ForwardPayload.displayText(item.text ?? '');
        final author = item.authorName.trim();
        if (body.isNotEmpty)
          lines.add(author.isEmpty ? body : '$author: $body');
        for (final file in item.attachments.take(10)) {
          lines.add(
              '📎 ${(file.name ?? '').trim().isEmpty ? 'Вложение' : file.name!.trim()}');
        }
      }
      text = lines.join('\n');
    }
    return MessageBubble(
        message: message.copyWith(text: text),
        time: DateFormat('HH:mm').format(message.at.toLocal()),
        showAvatar: showAuthor,
        reserveAvatarSpace: showAuthor,
        showAuthorLine: showAuthor,
        localOnlyUserId: service.currentUserId,
        localOnlyAttachmentBuilder: (file) =>
            CachedChatAttachment(file: file, service: service),
        attachments: message.attachments,
        reactions: message.reactions,
        receiptTicks: 0);
  }
}
