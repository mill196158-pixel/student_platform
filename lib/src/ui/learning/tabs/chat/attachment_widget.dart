import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'dart:async';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:flutter/material.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
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
      return _buildImageGrid(context, theme, files);
    } else if (isAllDocuments) {
      return _buildDocumentList(context, theme, files);
    } else {
      return _buildMixedContent(context, theme);
    }
  }

  Widget _buildImageGrid(
      BuildContext context, ThemeData theme, List<ChatFile> images) {
    final crossAxisCount = images.length == 1 ? 1 : 2;
    final aspectRatio = images.length == 1 ? 16 / 9 : 1.0;

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
        itemCount: images.length,
        itemBuilder: (context, index) {
          final file = images[index];
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
          AuthorizedFileImage(
            imageUrl: file.fileUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            placeholder: (context, url) => Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Center(child: ProductLoadingIndicator(size: 72)),
            ),
            errorWidget: (context, url, error) => Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentList(
      BuildContext context, ThemeData theme, List<ChatFile> documents) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        children:
            documents.map((file) => _buildDocumentItem(file, theme)).toList(),
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
          if (images.isNotEmpty) _buildImageGrid(context, theme, images),
          if (documents.isNotEmpty)
            _buildDocumentList(context, theme, documents),
        ],
      ),
    );
  }

  Future<void> _openFile(ChatFile file) async {
    try {
      final url = Uri.parse(await ChatFileAccess.resolve(file.fileUrl));
      if (await canLaunchUrl(url)) {
        final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
        if (opened) unawaited(ChatFileAccess.prepareDocumentForOffline(file.fileUrl));
      }
    } catch (e) {
      safeDebugLog('[AttachmentWidget] open file failed: ${e.runtimeType}');
    }
  }
}
