import 'package:flutter/material.dart';
import '../../models/message.dart';
import '../../models/chat_file.dart';
import '../../widgets/fullscreen_image.dart';
import 'assignment_bubble.dart';
import 'file_message_bubble.dart';
import 'multi_file_bubble.dart';
import 'message_bubble.dart';

typedef Bubble = Widget;

class _ForwardInfoBubble extends StatelessWidget {
  final ForwardPayloadModel payload;
  final bool isMine;
  final Key? boundaryKey;
  const _ForwardInfoBubble({
    required this.payload,
    required this.isMine,
    this.boundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: boundaryKey,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isMine
              ? Theme.of(context).colorScheme.primary.withValues(alpha: .10)
              : Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: .6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: .25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((payload.fromChatTitle ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Переслано из: ${payload.fromChatTitle}',
                style: t.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: t.bodySmall?.color?.withValues(alpha: .7),
                ),
              ),
            ),
          ...payload.items.map((it) => _ForwardInfoTile(item: it)),
        ]),
      ),
    );
  }
}

class _ForwardInfoTile extends StatelessWidget {
  final ForwardItemModel item;
  const _ForwardInfoTile({required this.item});

  String _fmt(DateTime dt) {
    final now = DateTime.now();
    final same =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (same) {
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    }
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$dd.$mo ${dt.year}';
  }

  bool _isImage(ForwardAttachmentModel attachment) {
    final name = (attachment.name ?? '').toLowerCase();
    final mime = (attachment.mime ?? '').toLowerCase();
    return mime.startsWith('image/') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp');
  }

  void _openAttachment(
      BuildContext context, ForwardAttachmentModel attachment) {
    final url = attachment.url;
    if (url.isEmpty) return;

    final name = (attachment.name ?? 'file').trim();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _isImage(attachment)
            ? FullscreenImage(
                imageUrl: url,
                fileName: name,
                sourceFileId: attachment.id,
              )
            : FullscreenFileViewer(
                fileUrl: url,
                fileName: name,
                fileSize: attachment.size ?? 0,
                mimeType: attachment.mime,
                sourceFileId: attachment.id,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final on = t.bodyMedium?.color ?? Colors.black;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: Colors.black12, borderRadius: BorderRadius.circular(14)),
            child: Text(
              (item.authorName.isNotEmpty
                      ? item.authorName.characters.first
                      : '•')
                  .toUpperCase(),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.authorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
              Text(_fmt(item.at),
                  style: t.labelSmall
                      ?.copyWith(color: on.withValues(alpha: .6), height: 1.1)),
              if ((item.text ?? '').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(item.text!, style: t.bodyMedium),
              ],
              if (item.attachments.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: item.attachments.map((a) {
                      final name = (a.name ?? 'file');
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _openAttachment(context, a),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(8)),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.attach_file, size: 16),
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 200),
                              child: Text(name,
                                  overflow: TextOverflow.ellipsis,
                                  style: t.bodySmall
                                      ?.copyWith(fontWeight: FontWeight.w600)),
                            ),
                          ]),
                        ),
                      );
                    }).toList()),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}

Bubble buildBubble({
  required Message m,
  required bool showAvatar,
  bool reserveAvatarSpace = true,
  bool showAuthorLine = true,
  required String time,
  required VoidCallback? onLongPress,
  required VoidCallback onReply,
  required void Function(String replyId) onReplyTap,
  String? replyPreview,
  String? authorAvatarUrl,
  String? authorName,
  List<ChatFile>? attachments,
  bool isMe = false,
  String? caption,
  required Map<String, Map<String, int>> reactions,
  required VoidCallback onReact,
  VoidCallback? onRetryFailed,
  bool selected = false,
  Key? boundaryKey,
  int? receiptTicks,
}) {
  // Current message reactions as counts
  final Map<String, int> currentCounts = reactions[m.id] ?? <String, int>{};
  if (m.type == MessageType.assignmentDraft ||
      m.type == MessageType.assignmentPublished) {
    return AssignmentBubble(
      message: m,
      isDraft: m.type == MessageType.assignmentDraft,
      time: time,
      reactions: currentCounts.isNotEmpty ? currentCounts : null,
      onReact: onReact,
      onLongPress: onLongPress,
      boundaryKey: boundaryKey,
    );
  }

  // Forward (server-side, msg_type = 'forward'): render compact forward bubble without root attachments
  if (m.type == MessageType.forward && m.forward != null) {
    return _ForwardInfoBubble(
      payload: m.forward!,
      isMine: isMe,
      boundaryKey: boundaryKey,
    );
  }

  // If this is a multi-forward (FG) message, always render with the universal MessageBubble
  // so attachments are not previewed as images/files but listed by name inside.
  final bool isFg = (m.text).contains('__FG__:');
  if (!isFg) {
    final files = attachments ?? m.attachments ?? const <ChatFile>[];
    if (files.isNotEmpty) {
      if (files.length == 1) {
        return FileMessageBubble(
          file: files.first,
          isMe: isMe,
          time: time,
          authorName: authorName ?? '',
          authorAvatarUrl: authorAvatarUrl,
          authorId: m.authorId,
          showAvatar: showAvatar,
          reserveAvatarSpace: reserveAvatarSpace,
          showAuthorLine: showAuthorLine,
          caption: caption,
          onLongPress: onLongPress,
          boundaryKey: boundaryKey,
          reactions: currentCounts.isNotEmpty ? currentCounts : null,
          onReact: onReact,
          selected: selected,
          receiptTicks: receiptTicks,
        );
      } else {
        return MultiFileBubble(
          files: files,
          isMe: isMe,
          time: time,
          authorName: authorName ?? '',
          authorAvatarUrl: authorAvatarUrl,
          authorId: m.authorId,
          showAvatar: showAvatar,
          reserveAvatarSpace: reserveAvatarSpace,
          showAuthorLine: showAuthorLine,
          text: m.text,
          onLongPress: onLongPress,
          boundaryKey: boundaryKey,
          reactions: currentCounts.isNotEmpty ? currentCounts : null,
          onReact: onReact,
          selected: selected,
          receiptTicks: receiptTicks,
        );
      }
    }
  }

  // Convert reactions format for MessageBubble
  Map<String, int>? messageReactions =
      currentCounts.isNotEmpty ? currentCounts : null;

  return MessageBubble(
    message: m,
    time: time,
    showAvatar: showAvatar,
    reserveAvatarSpace: reserveAvatarSpace,
    showAuthorLine: showAuthorLine,
    replyPreview: replyPreview,
    imagePath: m.imagePath,
    attachments: attachments ?? m.attachments,
    onLongPress: onLongPress,
    boundaryKey: boundaryKey,
    onReplyTap: onReplyTap,
    reactions: messageReactions,
    onReact: onReact,
    onRetryFailed: onRetryFailed,
    selected: selected,
    receiptTicks: receiptTicks,
  );
}
