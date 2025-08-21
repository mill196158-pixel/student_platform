import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/chat_file.dart';
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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        mainAxisAlignment: isOwnMessage ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isOwnMessage) const SizedBox(width: 40),
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              decoration: BoxDecoration(
                color: isOwnMessage 
                  ? Colors.blue.withOpacity(0.1)
                  : Colors.grey.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isOwnMessage 
                    ? Colors.blue.withOpacity(0.3)
                    : Colors.grey.withOpacity(0.3),
                  width: 1,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Превью изображения
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: CachedNetworkImage(
              imageUrl: file.fileUrl,
              width: 200,
              height: 150,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                width: 200,
                height: 150,
                color: Colors.grey[300],
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              ),
              errorWidget: (context, url, error) => Container(
                width: 200,
                height: 150,
                color: Colors.grey[300],
                child: const Center(
                  child: Icon(Icons.error, color: Colors.grey),
                ),
              ),
            ),
          ),
          // Информация о файле
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(file.fileIcon, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        file.fileName,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  file.formattedSize,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileCard(BuildContext context) {
    return GestureDetector(
      onTap: onTap ?? () {
        // TODO: Добавить скачивание/открытие файла
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Открытие файла: ${file.fileName}')),
        );
      },
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                file.fileIcon,
                size: 24,
                color: Colors.blue[700],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.fileName,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    file.formattedSize,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.download,
              size: 20,
              color: Colors.grey[600],
            ),
          ],
        ),
      ),
    );
  }
}
