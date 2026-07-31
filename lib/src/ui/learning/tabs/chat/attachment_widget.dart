import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';
import '../../models/chat_file.dart';
import '../../widgets/file_card.dart';

class AttachmentWidget extends StatelessWidget {
  final List<ChatFile> files;
  final bool isMe;
  final String time;

  const AttachmentWidget({
    super.key,
    required this.files,
    required this.isMe,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isAllImages = files.every((f) => f.isImage);
    final isAllDocuments = files.every((f) => !f.isImage);

    if (isAllImages && files.length <= 4) {
      return _buildImageGrid(context, theme);
    } else if (isAllDocuments) {
      return _buildDocumentList(context, theme);
    } else {
      return _buildMixedContent(context, theme);
    }
  }

  Widget _buildImageGrid(BuildContext context, ThemeData theme) {
    final crossAxisCount = files.length == 1 ? 1 : 2;
    final aspectRatio = files.length == 1 ? 16 / 9 : 1.0;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: 4,
          mainAxisSpacing: 4,
          childAspectRatio: aspectRatio,
        ),
        itemCount: files.length,
        itemBuilder: (context, index) {
          final file = files[index];
          return _buildImagePreview(file, theme, index);
        },
      ),
    );
  }

  Widget _buildImagePreview(ChatFile file, ThemeData theme, int index) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          CachedNetworkImage(
            imageUrl: file.fileUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            placeholder: (context, url) => Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(child: CircularProgressIndicator()),
            ),
            errorWidget: (context, url, error) => Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image),
            ),
          ),
          if (files.length > 4 && index == 3)
            Container(
              color: Colors.black.withValues(alpha: 0.6),
              child: Center(
                child: Text(
                  '+${files.length - 4}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDocumentList(BuildContext context, ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        children: files.map((file) => _buildDocumentItem(file, theme)).toList(),
      ),
    );
  }

  Widget _buildDocumentItem(ChatFile file, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: AppFileCard(
        fileName: file.fileName,
        fileSize: file.fileSize,
        mimeType: file.fileType,
        dense: true,
        onTap: () => _openFile(file),
        trailing: Icon(
          Icons.open_in_new_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildMixedContent(BuildContext context, ThemeData theme) {
    final images = files.where((f) => f.isImage).toList();
    final documents = files.where((f) => !f.isImage).toList();

    return Container(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (images.isNotEmpty) _buildImageGrid(context, theme),
          if (documents.isNotEmpty) _buildDocumentList(context, theme),
        ],
      ),
    );
  }

  Future<void> _openFile(ChatFile file) async {
    try {
      final url = Uri.parse(file.fileUrl);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      safeDebugLog('[AttachmentWidget] open file failed: ${e.runtimeType}');
    }
  }
}
