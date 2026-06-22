import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../models/chat_file.dart';
import '../../widgets/fullscreen_image.dart';
import '../../widgets/file_card.dart';
import 'profile_avatar.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';

class FileMessageBubble extends StatelessWidget {
  final ChatFile file;
  final bool isMe;
  final String time;
  final String authorName;
  final String? authorAvatarUrl;
  final String? authorId;
  final VoidCallback? onLongPress;
  final VoidCallback? onReact;
  final bool showAvatar;
  final bool reserveAvatarSpace;
  final bool showAuthorLine;
  final String? caption;
  final Map<String, int>? reactions;
  final bool selected;
  final Key? boundaryKey;

  const FileMessageBubble({
    super.key,
    required this.file,
    required this.isMe,
    required this.time,
    required this.authorName,
    this.authorAvatarUrl,
    this.authorId,
    this.onLongPress,
    this.onReact,
    this.showAvatar = true,
    this.reserveAvatarSpace = true,
    this.showAuthorLine = true,
    this.caption,
    this.reactions,
    this.selected = false,
    this.boundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color baseBg = isMe
        ? theme.colorScheme.primary.withValues(alpha: 0.22)
        : theme.colorScheme.surfaceContainerHighest;
    final Color bg = selected
        ? theme.colorScheme.surface.withValues(alpha: isMe ? 0.92 : 0.86)
        : baseBg;

    final textColor = theme.colorScheme.onSurface;
    final captionText = _realCaption(file, caption);
    final hasCaption = captionText != null;
    final displayTime = isMe ? '$time ✓' : time;
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final avatarSlots = !isMe && reserveAvatarSpace ? 40.0 : 0.0;
        final available = math.max(120.0, rowWidth - avatarSlots - 8);
        final widthFactor = file.isImage ? 0.9 : 0.78;
        final widthCap = file.isImage ? 360.0 : 300.0;
        final bubbleMaxWidth = math.min(
          rowWidth >= 700 ? widthCap : available * widthFactor,
          available,
        );
        final mediaInnerWidth =
            math.max(96.0, bubbleMaxWidth - (file.isImage ? 16 : 12));

        return GestureDetector(
          onLongPress: onLongPress,
          onTap: () => _handleFileTap(context),
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
                                onTap: (authorId != null &&
                                        authorId!.isNotEmpty)
                                    ? () => Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => FriendProfileScreen(
                                                userId: authorId!),
                                          ),
                                        )
                                    : null,
                                child: ProfileAvatar(
                                  name: authorName,
                                  imageUrl: authorAvatarUrl,
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
                    padding: EdgeInsets.zero,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isMe && showAuthorLine && hasCaption)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              authorName,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.primary,
                                fontSize: 12,
                              ),
                            ),
                          ),

                        if (file.isImage && !hasCaption) ...[
                          AppNetworkImagePreview(
                            imageUrl: file.fileUrl,
                            fileName: file.fileName,
                            maxWidth: mediaInnerWidth,
                            maxHeight: 270,
                            minHeight: 120,
                            borderRadius: 18,
                            fit: BoxFit.contain,
                            onTap: () => _handleFileTap(context),
                            overlay: Positioned(
                              bottom: 8,
                              right: 8,
                              child: _timePill(displayTime),
                            ),
                          ),
                        ] else if (!file.isImage && !hasCaption) ...[
                          AppFileCard(
                            fileName: file.fileName,
                            fileSize: file.fileSize,
                            mimeType: file.fileType,
                            compact: true,
                            maxNameLines: 1,
                            statusLabel: displayTime,
                            statusColor:
                                textColor.withValues(alpha: isMe ? .66 : .6),
                            backgroundColor: bg,
                            borderColor: theme.colorScheme.outlineVariant
                                .withValues(alpha: .18),
                            onTap: () => _handleFileTap(context),
                          ),
                        ] else ...[
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant
                                    .withValues(alpha: .16),
                                width: .6,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (file.isImage)
                                  AppNetworkImagePreview(
                                    imageUrl: file.fileUrl,
                                    fileName: file.fileName,
                                    maxWidth: mediaInnerWidth - 16,
                                    maxHeight: 270,
                                    minHeight: 120,
                                    borderRadius: 16,
                                    fit: BoxFit.contain,
                                    onTap: () => _handleFileTap(context),
                                  )
                                else
                                  AppFileCard(
                                    fileName: file.fileName,
                                    fileSize: file.fileSize,
                                    mimeType: file.fileType,
                                    compact: true,
                                    maxNameLines: 1,
                                    statusLabel: displayTime,
                                    statusColor: textColor.withValues(
                                        alpha: isMe ? .66 : .6),
                                    backgroundColor: Colors.transparent,
                                    borderColor: Colors.transparent,
                                    onTap: () => _handleFileTap(context),
                                  ),
                                if (captionText != null) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    captionText,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: textColor,
                                      height: 1.24,
                                    ),
                                  ),
                                ],
                                if (file.isImage) ...[
                                  const SizedBox(height: 3),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        displayTime,
                                        style: TextStyle(
                                          color:
                                              textColor.withValues(alpha: .6),
                                          fontSize: 11,
                                          height: 1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],

                        // Ряд реакций под баблом
                        if (reactions != null && reactions!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Align(
                            alignment: isMe
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: reactions!.entries
                                  .map((e) => GestureDetector(
                                        onTap: onReact,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.onSurface
                                                .withValues(
                                                    alpha: isMe ? .15 : .08),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text('${e.key} ${e.value}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: textColor)),
                                        ),
                                      ))
                                  .toList(),
                            ),
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

  String? _realCaption(ChatFile file, String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return null;
    final fileName = FileUiUtils.cleanFileName(file.fileName).trim();
    final normalizedRaw = raw.toLowerCase();
    final normalizedName = fileName.toLowerCase();
    if (normalizedRaw == normalizedName) return null;
    if (normalizedRaw == '📎 $normalizedName' ||
        normalizedRaw == 'file: $normalizedName' ||
        normalizedRaw == 'файл: $normalizedName') {
      return null;
    }
    return raw;
  }

  Widget _timePill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 10),
      ),
    );
  }

  Future<void> _handleFileTap(BuildContext context) async {
    if (file.isImage) {
      // Показываем изображение в полноэкранном режиме
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FullscreenImage(
            imageUrl: file.fileUrl,
            fileName: file.fileName,
          ),
        ),
      );
    } else {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => FullscreenFileViewer(
            fileUrl: file.fileUrl,
            fileName: file.fileName,
            fileSize: file.fileSize,
            mimeType: file.fileType,
          ),
        ),
      );
    }
  }
}
