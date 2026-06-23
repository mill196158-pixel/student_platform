import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../models/chat_file.dart';
import '../../widgets/file_card.dart';
import 'profile_avatar.dart'; // ДОБАВЛЕНО
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';
import '../../widgets/fullscreen_image.dart'; // ДОБАВЛЕНО

class MultiFileBubble extends StatelessWidget {
  final List<ChatFile> files;
  final bool isMe;
  final String time;
  final String? text;
  final bool showAvatar;
  final bool reserveAvatarSpace;
  final bool showAuthorLine;
  final String authorName;
  final String? authorAvatarUrl; // ДОБАВЛЕНО
  final String? authorId;
  final VoidCallback? onLongPress; // ДОБАВЛЕНО
  final Map<String, int>? reactions;
  final VoidCallback? onReact;
  final bool selected;
  final Key? boundaryKey;

  const MultiFileBubble({
    super.key,
    required this.files,
    required this.isMe,
    required this.time,
    this.text,
    this.showAvatar = true,
    this.reserveAvatarSpace = true,
    this.showAuthorLine = true,
    required this.authorName,
    this.authorAvatarUrl, // ДОБАВЛЕНО
    this.authorId,
    this.onLongPress, // ДОБАВЛЕНО
    this.reactions,
    this.onReact,
    this.selected = false,
    this.boundaryKey,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isAllImages = files.every((f) => f.isImage);
    final isAllDocuments = files.every((f) => !f.isImage);
    final displayTime = isMe ? '$time ✓' : time;
    final captionText = _realCaption;
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final avatarSlots = !isMe && reserveAvatarSpace ? 40.0 : 0.0;
        final available = math.max(120.0, rowWidth - avatarSlots - 8);
        final widthFactor = isAllImages ? 0.9 : 0.82;
        final widthCap = isAllImages ? 360.0 : 320.0;
        final bubbleMaxWidth = math.min(
          rowWidth >= 700 ? widthCap : available * widthFactor,
          available,
        );

        return Container(
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
                              onTap: (authorId != null && authorId!.isNotEmpty)
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
              GestureDetector(
                onLongPress: onLongPress,
                onTap: () {
                  // Тап по группе файлов — тоже центрируем сообщение
                  // Здесь нет прямого onReplyTap, но лист реагирует через SearchHighlight onTap
                },
                behavior: HitTestBehavior.opaque,
                child: ConstrainedBox(
                  key: boundaryKey,
                  constraints: BoxConstraints(
                    maxWidth: bubbleMaxWidth,
                  ),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: isAllImages ? 0 : 8,
                      vertical: isAllImages ? 0 : 8,
                    ),
                    decoration: BoxDecoration(
                      color: isAllImages
                          ? Colors.transparent
                          : (selected
                              ? theme.colorScheme.surface
                                  .withValues(alpha: isMe ? 0.92 : 0.86)
                              : (isMe
                                  ? theme.colorScheme.primary
                                      .withValues(alpha: 0.22)
                                  : theme.colorScheme.surfaceContainerHighest)),
                      border: isAllImages
                          ? null
                          : Border.all(
                              color: theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.8)),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isMe && showAuthorLine && captionText != null) ...[
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
                        ],

                        // Медиа блок
                        _buildMediaContent(
                            context, theme, isAllImages, isAllDocuments),

                        // Подпись и время в ОДНОЙ строке, прижатой к стороне отправителя (если есть подпись)
                        if (captionText != null) ...[
                          const SizedBox(height: 8),
                          _captionWithTime(theme, displayTime, captionText),
                        ] else if (!isAllImages) ...[
                          // Если подписи нет и это не чисто изображения — время отдельной строкой у стороны отправителя
                          Row(
                            mainAxisAlignment: isMe
                                ? MainAxisAlignment.end
                                : MainAxisAlignment.start,
                            children: [
                              Text(
                                displayTime,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
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
                                            color: Colors.black.withValues(
                                                alpha: isMe ? .15 : .08),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: Text('${e.key} ${e.value}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: theme
                                                      .colorScheme.onSurface)),
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
              ),
            ],
          ),
        );
      },
    );
  }

  String? get _realCaption {
    final raw = (text ?? '').trim();
    if (raw.isEmpty) return null;
    final normalizedRaw = raw.toLowerCase();
    for (final file in files) {
      final normalizedName =
          FileUiUtils.cleanFileName(file.fileName).toLowerCase();
      if (normalizedRaw == normalizedName ||
          normalizedRaw == '📎 $normalizedName' ||
          normalizedRaw == 'file: $normalizedName' ||
          normalizedRaw == 'файл: $normalizedName') {
        return null;
      }
    }
    return raw;
  }

  List<ChatFile> get _imageFiles => files.where((f) => f.isImage).toList();

  List<ChatFile> get _documentFiles => files.where((f) => !f.isImage).toList();

  Widget _captionWithTime(
    ThemeData theme,
    String displayTime,
    String captionText,
  ) {
    final caption = Expanded(
      child: Text(
        captionText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: theme.colorScheme.onSurface,
          fontSize: 14,
        ),
      ),
    );

    final timeWidget = Text(
      displayTime,
      style: TextStyle(
        fontSize: 10,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    // Время ближе к стороне отправителя: справа у моих, слева у входящих
    return Row(
      children: isMe
          ? [caption, const SizedBox(width: 8), timeWidget]
          : [timeWidget, const SizedBox(width: 8), caption],
    );
  }

  Widget _buildMediaContent(BuildContext context, ThemeData theme,
      bool isAllImages, bool isAllDocuments) {
    if (isAllImages && files.length <= 4) {
      return _buildImageGrid(context, theme, _imageFiles);
    } else if (isAllDocuments) {
      return _buildDocumentList(context, theme, _documentFiles);
    } else {
      return _buildMixedContent(context, theme);
    }
  }

  Widget _buildImageGrid(
    BuildContext context,
    ThemeData theme,
    List<ChatFile> images,
  ) {
    if (images.isEmpty) return const SizedBox.shrink();

    if (images.length == 1) {
      final file = images.first;
      return AppNetworkImagePreview(
        imageUrl: file.fileUrl,
        fileName: file.fileName,
        maxWidth: MediaQuery.sizeOf(context).width >= 700 ? 324.0 : null,
        maxHeight: 270,
        minHeight: 120,
        borderRadius: 18,
        fit: BoxFit.contain,
        onTap: () => _openImageFullscreen(context, file, images),
        overlay: _realCaption == null && time.isNotEmpty
            ? Positioned(
                bottom: 8,
                right: 8,
                child: _timePill(isMe ? '$time ✓' : time),
              )
            : null,
      );
    }

    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
            final cellSize = ((width - 4) / 2).clamp(120.0, 220.0).toDouble();

            return SizedBox(
              width: cellSize * 2 + 4,
              child: GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                  childAspectRatio: 1,
                ),
                itemCount: images.length > 4 ? 4 : images.length,
                itemBuilder: (context, index) {
                  final file = images[index];
                  final isLast = index == 3 && images.length > 4;

                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        onLongPress: onLongPress,
                        child: AppNetworkImagePreview(
                          imageUrl: file.fileUrl,
                          fileName: file.fileName,
                          minHeight: cellSize,
                          maxHeight: cellSize,
                          maxWidth: cellSize,
                          borderRadius: 10,
                          fit: BoxFit.cover,
                          onTap: () => _openImageFullscreen(
                            context,
                            file,
                            images,
                          ),
                        ),
                      ),
                      if (isLast)
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: Text(
                              '+${images.length - 4}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            );
          },
        ),
        if (_realCaption == null && time.isNotEmpty)
          Positioned(
            bottom: 4,
            right: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isMe ? '$time ✓' : time,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDocumentList(
    BuildContext context,
    ThemeData theme,
    List<ChatFile> documents,
  ) {
    return Column(
      children: documents
          .map((file) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildDocumentItem(context, file, theme),
              ))
          .toList(),
    );
  }

  Widget _buildDocumentItem(
      BuildContext context, ChatFile file, ThemeData theme) {
    return AppFileCard(
      fileName: file.fileName,
      fileSize: file.fileSize,
      mimeType: file.fileType,
      compact: true,
      maxNameLines: 1,
      backgroundColor: Colors.transparent,
      borderColor: Colors.transparent,
      onTap: () => _openFile(context, file),
    );
  }

  Widget _buildMixedContent(BuildContext context, ThemeData theme) {
    final images = _imageFiles;
    final documents = _documentFiles;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (images.isNotEmpty) ...[
          _buildImageGrid(context, theme, images),
          if (documents.isNotEmpty) const SizedBox(height: 8),
        ],
        if (documents.isNotEmpty) ...[
          _buildDocumentList(context, theme, documents),
        ],
      ],
    );
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

  void _openFile(BuildContext context, ChatFile file) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenFileViewer(
          fileUrl: file.fileUrl,
          fileName: file.fileName,
          fileSize: file.fileSize,
          mimeType: file.fileType,
          sourceFileId: file.id,
        ),
      ),
    );
  }

  void _openImageFullscreen(
    BuildContext context,
    ChatFile file,
    List<ChatFile> images,
  ) {
    final currentIndexInImages = images.indexWhere((x) => x.id == file.id);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullscreenImage(
          imageUrl: file.fileUrl,
          fileName: file.fileName,
          sourceFileId: file.id,
          galleryUrls: images.map((e) => e.fileUrl).toList(),
          galleryFileNames: images.map((e) => e.fileName).toList(),
          galleryFileIds: images.map((e) => e.id).toList(),
          initialIndex: currentIndexInImages < 0 ? 0 : currentIndexInImages,
        ),
      ),
    );
  }
}
