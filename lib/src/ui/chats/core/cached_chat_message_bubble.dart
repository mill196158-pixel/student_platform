import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:student_platform/src/ui/chats/core/cached_chat_attachment.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/message_bubble.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/models/chat_card_envelope.dart';

/// Existing message presentation with no online avatar, actions or file fetch.
class CachedChatMessageBubble extends StatelessWidget {
  const CachedChatMessageBubble(
      {super.key,
      required this.message,
      required this.service,
      required this.showAuthor,
      this.debugForwardAttachmentBuilder});
  final Message message;
  final DmChatService service;
  final bool showAuthor;
  @visibleForTesting
  final Widget Function(ChatFile)? debugForwardAttachmentBuilder;

  @override
  Widget build(BuildContext context) {
    final embedded = ForwardPayload.tryParse(message.text);
    final canonical = message.attachments ?? const <ChatFile>[];
    final matched = <ChatFile>[];
    final matchedIds = <String>{};
    var remainingItems = 30;
    var remainingFiles = 30;
    bool addFile(String? id, String url, String name, List<String> lines) {
      final candidates = canonical.where((f) => id != null && id.isNotEmpty && f.id == id).toList();
      final urlMatches = canonical.where((f) => f.fileUrl == url).toList();
      if (candidates.length == 1 && urlMatches.length == 1 &&
          identical(candidates.single, urlMatches.single)) {
        final file = candidates.single;
        if (file.isDeleted) return true;
        if (file.deletionVerified) {
          if (matchedIds.add(file.id)) matched.add(file);
          return true;
        }
      }
      lines.add('📎 ${name.trim().isEmpty ? 'Вложение' : name.trim()}');
      return false;
    }
    void addEmbedded(ForwardPayload payload, List<String> lines, int depth) {
      if (depth > 3) return;
      if ((payload.caption ?? '').trim().isNotEmpty) {
        lines.add(ForwardPayload.displayText(payload.caption!));
      }
      for (final item in payload.items) {
        if (remainingItems-- <= 0) break;
        final nested = depth < 3 ? ForwardPayload.tryParse(item.text) : null;
        if (nested != null) {
          addEmbedded(nested, lines, depth + 1);
        } else {
          final body = ForwardPayload.displayText(item.text);
          final author = item.authorName.trim();
          if (body.isNotEmpty) lines.add(author.isEmpty ? body : '$author: $body');
          else if (author.isNotEmpty) lines.add(author);
        }
        for (final file in item.files.take(10)) {
          if (remainingFiles-- <= 0) break;
          addFile(file.id, file.url, file.name, lines);
        }
      }
    }
    var text = ChatCardPreview.forPreview(message);
    if (embedded != null) {
      final lines = <String>['Пересланные сообщения'];
      addEmbedded(embedded, lines, 0);
      text = lines.join('\n');
    } else if (message.type == MessageType.forward && message.forward != null) {
      final lines = <String>['Пересланные сообщения'];
      for (final item in message.forward!.items.take(30)) {
        final body = ForwardPayload.displayText(item.text ?? '');
        final author = item.authorName.trim();
        if (body.isNotEmpty)
          lines.add(author.isEmpty ? body : '$author: $body');
        else if (author.isNotEmpty) lines.add(author);
        for (final file in item.attachments.take(10)) {
          addFile(file.id, file.url, file.name ?? '', lines);
        }
      }
      text = lines.join('\n');
    }
    // Older structured-forward snapshots did not preserve whether their
    // author label came from the server or a generated fallback. Avoid
    // guessing from the literal name; retain all message and forwarded text.
    final displayAuthor = showAuthor &&
        (message.type != MessageType.forward || message.authorNameVerified == true);
    final bubble = MessageBubble(
        message: message.copyWith(text: text),
        time: DateFormat('HH:mm').format(message.at.toLocal()),
        showAvatar: displayAuthor,
        reserveAvatarSpace: displayAuthor,
        showAuthorLine: displayAuthor,
        localOnlyUserId: service.currentUserId,
        localOnlyAttachmentBuilder: (file) =>
            kDebugMode && debugForwardAttachmentBuilder != null
                ? debugForwardAttachmentBuilder!(file)
                : CachedChatAttachment(file: file, service: service),
        attachments: canonical.where((f) {
          if (f.isDeleted || matchedIds.contains(f.id)) return false;
          if (embedded == null && message.type != MessageType.forward) return true;
          return f.deletionVerified && f.id.isNotEmpty && f.fileUrl.isNotEmpty &&
              canonical.where((x) => x.id == f.id).length == 1 &&
              canonical.where((x) => x.fileUrl == f.fileUrl).length == 1;
        }).toList(),
        reactions: message.reactions,
        receiptTicks: 0);
    if (matched.isEmpty) return bubble;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [bubble, for (final file in matched)
          Padding(padding: const EdgeInsets.only(left: 40, top: 4),
            child: SizedBox(width: 280, child:
              kDebugMode && debugForwardAttachmentBuilder != null
                  ? debugForwardAttachmentBuilder!(file)
                  : CachedChatAttachment(file: file, service: service))) ]);
  }
}
