import 'package:flutter/material.dart';
import '../models/chat_file.dart';
import 'file_card.dart';
import 'fullscreen_image.dart';

class FileMessageBubble extends StatelessWidget {
  final ChatFile file;
  final bool isOwnMessage;
  final VoidCallback? onTap;

  const FileMessageBubble({
    super.key,
    required this.file,
    required this.isOwnMessage,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        mainAxisAlignment:
            isOwnMessage ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isOwnMessage) const SizedBox(width: 40),
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              decoration: BoxDecoration(
                color: isOwnMessage
                    ? scheme.primary.withValues(alpha: 0.22)
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.8),
                ),
              ),
              child: _buildFileContent(context),
            ),
          ),
          if (isOwnMessage) const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildFileContent(BuildContext context) {
    if (file.isImage) {
      return _buildImagePreview(context);
    } else {
      return _buildFileCard(context);
    }
  }

  Widget _buildImagePreview(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FullscreenImage(
              imageUrl: file.fileUrl,
              fileName: file.fileName,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: AppNetworkImagePreview(
          imageUrl: file.fileUrl,
          fileName: file.fileName,
          minHeight: 140,
          maxHeight: 190,
        ),
      ),
    );
  }

  Widget _buildFileCard(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: AppFileCard(
        fileName: file.fileName,
        fileSize: file.fileSize,
        mimeType: file.fileType,
        onTap: onTap ??
            () {
              // TODO: Добавить скачивание/открытие файла
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      'Открытие файла: ${FileUiUtils.cleanFileName(file.fileName)}'),
                ),
              );
            },
        trailing: Icon(
          Icons.open_in_new_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
