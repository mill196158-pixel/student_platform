// FILE: lib/src/ui/chats/core/dm_composer_bar.dart
// ignore_for_file: unused_element, unused_field
import 'dart:io';
import 'package:flutter/material.dart';

import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/typing_line.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart'
    show AttachedFile, Composer;

class DmComposerBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  final Message? replyTo;
  final VoidCallback onCloseReply;
  final int forwardCount;
  final String? forwardPreview;
  final VoidCallback? onCancelForward;

  final bool someoneTyping;
  final List<String> typingNames;

  final List<AttachedFile> attachedFiles;

  final VoidCallback onSend;
  final Future<void> Function() onPickImage;
  final VoidCallback onOpenEmoji;
  final Future<void> Function()? onAttachFile;
  final void Function(AttachedFile file) onRemoveFile;
  final void Function(AttachedFile file) onAddFile;
  final void Function(AttachedFile file)? onRetryFile;

  final void Function(String text) onPinText;

  // sending/upload state to control send button
  final bool isUploading;
  final bool hasFailedUploads;
  final bool isSending;

  const DmComposerBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.replyTo,
    required this.onCloseReply,
    this.forwardCount = 0,
    this.forwardPreview,
    this.onCancelForward,
    required this.someoneTyping,
    required this.typingNames,
    required this.attachedFiles,
    required this.onSend,
    required this.onPickImage,
    required this.onOpenEmoji,
    required this.onAttachFile,
    required this.onRemoveFile,
    required this.onAddFile,
    this.onRetryFile,
    required this.onPinText,
    this.isUploading = false,
    this.hasFailedUploads = false,
    this.isSending = false,
  });

  @override
  Widget build(BuildContext context) {
    final themed = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (replyTo != null)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: themed.colorScheme.surface.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: themed.colorScheme.outline.withValues(alpha: .25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.reply, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(replyTo!.text,
                        maxLines: 2, overflow: TextOverflow.ellipsis)),
                IconButton(
                    icon: const Icon(Icons.close), onPressed: onCloseReply),
              ],
            ),
          ),
        if (someoneTyping) TypingLine(names: typingNames),
        Composer(
          controller: controller,
          focusNode: focusNode,
          pickedImagePath: null,
          attachedFiles: attachedFiles,
          forwardCount: forwardCount,
          forwardPreview: forwardPreview,
          onCancelForward: onCancelForward,
          onAddFile: onAddFile,
          onRemoveFile: onRemoveFile,
          onRetryFile: onRetryFile,
          onOpenEmoji: onOpenEmoji,
          onSend: onSend,
          onClearPicked: () {},
          onPickImage: onPickImage,
          onAttachFile: onAttachFile,
          isUploading: isUploading,
          hasFailedUploads: hasFailedUploads,
          isSending: isSending,
          leftButton: _DmPlusButton(
            onPickImage: onPickImage,
            onAttachFile: onAttachFile,
          ),
        ),
      ],
    );
  }
}

class _DmComposer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;

  final List<AttachedFile> attachedFiles;
  final Function(AttachedFile) onRemoveFile;
  final Function(AttachedFile) onAddFile;

  final VoidCallback onOpenEmoji;
  final VoidCallback onSend;
  final Future<void> Function() onPickImage;
  final Future<void> Function()? onAttachFile;

  final void Function(String text) onPinText;

  const _DmComposer({
    required this.controller,
    required this.focusNode,
    required this.attachedFiles,
    required this.onRemoveFile,
    required this.onAddFile,
    required this.onOpenEmoji,
    required this.onSend,
    required this.onPickImage,
    required this.onAttachFile,
    required this.onPinText,
  });

  static const int maxFiles = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (attachedFiles.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                height: 80,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: attachedFiles.length,
                  itemBuilder: (context, index) {
                    final file = attachedFiles[index];
                    return Container(
                      margin: const EdgeInsets.only(right: 8),
                      width: 80,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: theme.colorScheme.outline
                                .withValues(alpha: .2)),
                      ),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: file.isImage
                                ? Image.file(File(file.path),
                                    fit: BoxFit.cover, width: 80, height: 80)
                                : Center(
                                    child: Icon(_getFileIcon(file.name),
                                        size: 28,
                                        color: theme.colorScheme.onSurface
                                            .withValues(alpha: .6)),
                                  ),
                          ),
                          Positioned(
                            right: 4,
                            top: 4,
                            child: InkWell(
                              onTap: () => onRemoveFile(file),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: .6),
                                  shape: BoxShape.circle,
                                ),
                                padding: const EdgeInsets.all(2),
                                child: const Icon(Icons.close,
                                    size: 14, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // ПЛЮС — круглая кнопка (в ЛС только тут)
                _DmPlusButton(
                  onPickImage: onPickImage,
                  onAttachFile: onAttachFile,
                ),
                const SizedBox(width: 8),

                // Поле ввода
                Expanded(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                          color:
                              theme.colorScheme.outline.withValues(alpha: .25)),
                    ),
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Сообщение',
                        isDense: true,
                      ),
                      onTap: onOpenEmoji,
                    ),
                  ),
                ),

                const SizedBox(width: 8),

                // Отправить
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: onSend,
                    tooltip: 'Отправить',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'ppt':
      case 'pptx':
        return Icons.slideshow;
      case 'txt':
        return Icons.text_snippet;
      case 'zip':
      case 'rar':
        return Icons.folder_zip;
      default:
        return Icons.attach_file;
    }
  }
}

class _DmPlusButton extends StatelessWidget {
  final Future<void> Function() onPickImage;
  final Future<void> Function()? onAttachFile;

  const _DmPlusButton({
    required this.onPickImage,
    required this.onAttachFile,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () async {
          await showModalBottomSheet(
            context: context,
            showDragHandle: true,
            backgroundColor: theme.colorScheme.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
            ),
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.image),
                    title: const Text('Фото из галереи'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await onPickImage();
                    },
                  ),
                  if (onAttachFile != null)
                    ListTile(
                      leading: const Icon(Icons.attach_file),
                      title: const Text('Файл'),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await onAttachFile!();
                      },
                    ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          );
        },
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.add, size: 22),
        ),
      ),
    );
  }
}
