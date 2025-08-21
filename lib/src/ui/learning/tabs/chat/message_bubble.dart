// =============================
// FILE: lib/src/ui/learning/tabs/chat/message_bubble.dart
// =============================

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/message.dart';
import 'profile_avatar.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final String time;
  final String? replyPreview;
  final String? imagePath;
  final Map<String, int>? reactions;
  final VoidCallback? onLongPress;
  final void Function(String emoji)? onReact;

  const MessageBubble({
    super.key,
    required this.message,
    required this.time,
    this.replyPreview,
    this.imagePath,
    this.reactions,
    this.onLongPress,
    this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    final currentUid = Supabase.instance.client.auth.currentUser?.id;

    final isMe = message.isMine(currentUid);
    final isSystem = message.isSystem;

    final theme = Theme.of(context);
    final maxW = math.min(MediaQuery.of(context).size.width * 0.78, 420.0);

    final bg = isSystem
        ? theme.colorScheme.tertiaryContainer.withOpacity(.6)
        : (isMe
            ? theme.colorScheme.primary.withOpacity(0.22) // чуть темнее для моих сообщений
            : theme.colorScheme.surfaceContainerHighest);

    final textColor = isSystem
        ? theme.colorScheme.onTertiaryContainer
        : Colors.black87;

    final bubble = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: Colors.black12),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe && !isSystem)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  message.authorName,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                    fontSize: 12,
                  ),
                ),
              ),
            if (replyPreview != null && replyPreview!.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 2),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isMe ? Colors.black.withOpacity(.12) : Colors.black12,
                  borderRadius: BorderRadius.circular(12),
                  border: Border(
                      left: BorderSide(
                          color: textColor.withOpacity(.4), width: 3)),
                ),
                child: Text(
                  replyPreview!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: textColor.withOpacity(.85),
                      fontStyle: FontStyle.italic),
                ),
              ),
            if (imagePath != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: Image.file(File(imagePath!), fit: BoxFit.cover),
                ),
              ),
              if (message.text.isNotEmpty) const SizedBox(height: 6),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(message.text,
                      style: TextStyle(color: textColor, height: 1.24)),
                ),
                const SizedBox(width: 8),
                Text(time,
                    style: TextStyle(
                        color: textColor.withOpacity(.6), fontSize: 11)),
              ],
            ),
            if (reactions != null && reactions!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: reactions!.entries
                    .map((e) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(isMe ? .15 : .08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text('${e.key} ${e.value}',
                              style:
                                  TextStyle(color: textColor, fontSize: 12)),
                        ))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );

    return GestureDetector(
      onLongPress: onLongPress,
      child: Row(
        mainAxisAlignment:
            isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe)
            ProfileAvatar(
              name: message.authorName,
              imageUrl: message.authorAvatarUrl,
            ),
          if (!isMe) const SizedBox(width: 8),
          Flexible(child: bubble),
          if (isMe) const SizedBox(width: 8),
          if (isMe)
            ProfileAvatar(
              name: (message.authorName.isNotEmpty
                  ? message.authorName
                  : 'Вы'),
              imageUrl: message.authorAvatarUrl,
            ),
        ],
      ),
    );
  }
}
