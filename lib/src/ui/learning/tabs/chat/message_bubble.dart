// =============================
// FILE: lib/src/ui/learning/tabs/chat/message_bubble.dart
// =============================

import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/message.dart';
import '../../models/chat_file.dart';
import '../../widgets/file_card.dart';
import 'profile_avatar.dart';
import 'multi_file_bubble.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';
import 'forward_group_bubble.dart';
import 'message_receipt.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final String time;
  final String? replyPreview;
  final String? imagePath;
  final List<ChatFile>? attachments;
  final Map<String, int>? reactions;
  final VoidCallback? onLongPress;
  final VoidCallback? onReact;
  final VoidCallback? onRetryFailed;
  final bool showAvatar;
  final bool reserveAvatarSpace;
  final bool showAuthorLine;
  final Function(String)? onReplyTap;
  final Key? boundaryKey;
  final bool selected;

  /// DM receipts: null = legacy single ✓; 0/1/2 = none/delivered/read.
  final int? receiptTicks;

  const MessageBubble({
    super.key,
    required this.message,
    required this.time,
    this.replyPreview,
    this.imagePath,
    this.attachments,
    this.reactions,
    this.onLongPress,
    this.onReact,
    this.onRetryFailed,
    this.showAvatar = true,
    this.reserveAvatarSpace = true,
    this.showAuthorLine = true,
    this.onReplyTap,
    this.boundaryKey,
    this.selected = false,
    this.receiptTicks,
  });

  Map<String, dynamic>? _parseForwardGroup(String text) {
    final idx = text.indexOf('__FG__:');
    if (idx < 0) return null;
    final payload = text.substring(idx + '__FG__:'.length).trim();
    try {
      final decoded = jsonDecode(payload) as Map<String, dynamic>;
      if (decoded['fg'] == 1 && decoded['items'] is List) return decoded;
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMe = message.isMine(Supabase.instance.client.auth.currentUser?.id);

    final baseBg = isMe
        ? theme.colorScheme.primary.withValues(alpha: 0.22)
        : theme.colorScheme.surfaceContainerHighest;

    // Если выбран/под меню — одинаково высветляем оба типа
    final Color bg =
        selected ? Colors.white.withValues(alpha: isMe ? 0.85 : 0.78) : baseBg;

    final textColor = Colors.black87;
    final displayTime = formatMessageTimeLabel(
      time: time,
      isMe: isMe,
      receiptTicks: receiptTicks,
      isEdited: message.isEdited,
      isSending: message.isSending,
    );

    final bool hasFgMarker = message.text.contains('__FG__:');
    final fg = _parseForwardGroup(message.text);
    final Map<String, ChatFile> idToFile = {
      for (final f in (attachments ?? const <ChatFile>[])) f.id: f
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final avatarSlots = !isMe && reserveAvatarSpace ? 40.0 : 0.0;
        final available = math.max(120.0, rowWidth - avatarSlots - 8);
        final bubbleMaxWidth = math.min(
          rowWidth >= 700 ? 380.0 : available * 0.9,
          available,
        );

        return GestureDetector(
          onLongPress: onLongPress,
          onTap: () {
            // Центрируем текущее сообщение по тачу
            if (onReplyTap != null) {
              onReplyTap!(message.id);
            }
          },
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisAlignment:
                  isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMe && reserveAvatarSpace)
                  SizedBox(
                    width: 40,
                    child: showAvatar
                        ? Row(
                            children: [
                              InkWell(
                                onTap: message.authorId.isNotEmpty
                                    ? () => Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => FriendProfileScreen(
                                                userId: message.authorId),
                                          ),
                                        )
                                    : null,
                                child: ProfileAvatar(
                                  name: message.authorName,
                                  imageUrl: message.authorAvatarUrl,
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                          )
                        : null,
                  ),

                // Bubble с динамической шириной
                ConstrainedBox(
                  key: boundaryKey,
                  constraints: BoxConstraints(
                    maxWidth: bubbleMaxWidth,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: bg,
                      border: Border.all(
                          color: Colors.black.withValues(alpha: .06)),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isMe && showAuthorLine)
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

                        if (replyPreview != null ||
                            (message.attachments != null &&
                                message.attachments!.isNotEmpty)) ...[
                          GestureDetector(
                            onTap: () {
                              // Навигация к исходному сообщению
                              if (message.replyToId != null &&
                                  onReplyTap != null) {
                                onReplyTap!(message.replyToId!);
                              }
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.05),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: Colors.black.withValues(alpha: 0.1)),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.reply,
                                    size: 14,
                                    color: textColor.withValues(alpha: 0.7),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      replyPreview ??
                                          _buildAttachmentPreviewText(),
                                      style: TextStyle(
                                        color: textColor.withValues(alpha: 0.7),
                                        fontSize: 12,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],

                        if (!hasFgMarker && imagePath != null) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Stack(
                              children: [
                                Image.file(
                                  File(imagePath!),
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                ),
                                // Время поверх изображения
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.black.withValues(alpha: 0.6),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      displayTime,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (message.text.isNotEmpty)
                            const SizedBox(height: 6),
                        ],

                        // FG-группа: используем новый красивый рендер бабла пересылки
                        if (fg != null) ...[
                          ForwardGroupBubble(
                            message: message,
                            time: displayTime,
                            isMe: isMe,
                            selected: selected,
                            idToFile: idToFile,
                            // По требованию: отключаем переход к исходному сообщению из пересылки
                            onOpenOriginal: null,
                            onLongPress: onLongPress,
                            onReact: onReact,
                            reactions: reactions,
                            onRetryFailed: message.isFailed ? onRetryFailed : null,
                          ),
                        ],

                        // Текст/время выводим ТОЛЬКО когда это НЕ FG-сообщение.
                        if (fg == null) ...[
                          if (message.text.isNotEmpty) ...[
                            _TextMessageContent(
                              text: message.text,
                              time: displayTime,
                              textColor: textColor,
                            ),
                          ] else if (imagePath == null &&
                              (attachments == null ||
                                  attachments!.isEmpty)) ...[
                            // Только время для сообщений без текста, изображений и вложений
                            Align(
                              alignment: Alignment.bottomRight,
                              child: Text(
                                displayTime,
                                style: TextStyle(
                                  color: textColor.withValues(alpha: .6),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ],

                        // Вложения (файлы) — показываем стандартный компонент, НО только для НЕ FG сообщений
                        if (attachments != null &&
                            attachments!.isNotEmpty &&
                            fg == null) ...[
                          MultiFileBubble(
                            files: attachments!,
                            isMe: isMe,
                            time: time,
                            text: message.text.isNotEmpty ? message.text : null,
                            showAvatar: false,
                            authorName: message.authorName,
                            receiptTicks: receiptTicks,
                          ),
                        ],

                        if (reactions != null && reactions!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: reactions!.entries
                                .map((e) => GestureDetector(
                                      onTap: onReact,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                              alpha: isMe ? .15 : .08),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Text('${e.key} ${e.value}',
                                            style: TextStyle(
                                                color: textColor,
                                                fontSize: 12)),
                                      ),
                                    ))
                                .toList(),
                          ),
                        ],
                        if (message.isFailed) ...[
                          const SizedBox(height: 6),
                          _DeliveryStateRow(
                            onRetry: onRetryFailed,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _buildAttachmentPreviewText() {
    try {
      final atts = message.attachments ?? const <ChatFile>[];
      if (atts.isEmpty) return 'Вложение';
      if (atts.length == 1) {
        final f = atts.first;
        final name = FileUiUtils.cleanFileName(f.fileName);
        return name.isNotEmpty ? name : 'Вложение';
      }
      // несколько файлов
      final first = FileUiUtils.cleanFileName(atts.first.fileName);
      final rest = atts.length - 1;
      return rest > 0
          ? '$first +$rest'
          : (first.isNotEmpty ? first : 'Вложения');
    } catch (_) {
      return 'Вложение';
    }
  }
}

class _TextMessageContent extends StatelessWidget {
  final String text;
  final String time;
  final Color textColor;

  const _TextMessageContent({
    required this.text,
    required this.time,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(color: textColor, height: 1.24);
    final timeStyle = TextStyle(
      color: textColor.withValues(alpha: .6),
      fontSize: 11,
      height: 1.0,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width * .72;
        final direction = Directionality.of(context);
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: textStyle),
          textDirection: direction,
          maxLines: 1,
        )..layout(maxWidth: maxWidth);
        final timePainter = TextPainter(
          text: TextSpan(text: time, style: timeStyle),
          textDirection: direction,
          maxLines: 1,
        )..layout();
        final oneLineFits =
            textPainter.width + timePainter.width + 10 <= maxWidth;

        if (oneLineFits) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: Text(
                  text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 1),
                child: Text(time, style: timeStyle),
              ),
            ],
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              softWrap: true,
              style: textStyle,
            ),
            const SizedBox(height: 3),
            Align(
              alignment: Alignment.centerRight,
              child: Text(time, style: timeStyle),
            ),
          ],
        );
      },
    );
  }
}

class _DeliveryStateRow extends StatelessWidget {
  final VoidCallback? onRetry;

  const _DeliveryStateRow({
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;

    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: color),
          Text(
            'Не отправлено',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onRetry != null)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onRetry,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  'Повторить',
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
