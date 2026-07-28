import 'package:flutter/material.dart';
import '../../../models/message.dart';
import '../composer.dart';
import '../typing_line.dart';
import '../assignments/assignment_form_dialog.dart';
import 'chat_plus_menu.dart';

class ChatComposerBar extends StatelessWidget {
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
  final Future<void> Function()? onPasteFile;
  final void Function(AttachedFile file) onRemoveFile;
  final void Function(AttachedFile file) onAddFile;
  final void Function(AttachedFile file)? onRetryFile;

  final void Function(String text) onPinText;
  final Future<void> Function() onFind;
  final Future<void> Function(String title, String description, String? link,
      String? due, List<Map<String, String>> attachments) onPropose;

  // Controls for showing actions in the plus menu; default true to not break callers
  final bool showFindInPlus;
  final bool showProposeInPlus;
  final bool showTopicSelectionInPlus;
  final bool showCollectionInPlus;
  final bool proposeEnabled;
  final bool topicSelectionEnabled;
  final bool collectionEnabled;
  final bool capabilitiesLoading;
  final String? proposeDisabledReason;
  final String? topicSelectionDisabledReason;
  final String? collectionDisabledReason;
  final VoidCallback? onOpenTopicSelection;
  final VoidCallback? onOpenCollection;

  // sending/upload state to control send button
  final bool isUploading;
  final bool hasFailedUploads;
  final bool isSending;

  const ChatComposerBar({
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
    this.onPasteFile,
    required this.onRemoveFile,
    required this.onAddFile,
    this.onRetryFile,
    required this.onPinText,
    required this.onFind,
    required this.onPropose,
    this.showFindInPlus = true,
    this.showProposeInPlus = true,
    this.showTopicSelectionInPlus = false,
    this.showCollectionInPlus = false,
    this.proposeEnabled = true,
    this.topicSelectionEnabled = true,
    this.collectionEnabled = true,
    this.capabilitiesLoading = false,
    this.proposeDisabledReason,
    this.topicSelectionDisabledReason,
    this.collectionDisabledReason,
    this.onOpenTopicSelection,
    this.onOpenCollection,
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
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
            decoration: BoxDecoration(
              color: themed.colorScheme.surface.withValues(alpha: .6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: themed.colorScheme.outline.withValues(alpha: .25)),
            ),
            child: Row(
              children: [
                Icon(_replyIcon(replyTo!), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _replyAuthor(replyTo!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: themed.textTheme.labelSmall?.copyWith(
                          color: themed.colorScheme.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _replyPreview(replyTo!),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: themed.textTheme.bodyMedium?.copyWith(
                          color: themed.colorScheme.onSurface,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
                ),
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
          onPasteFile: onPasteFile,
          leftButton: ChatPlusButton(
            actions: [
              if (showProposeInPlus)
                ChatPlusAction(
                  icon: Icons.assignment_add,
                  title: 'Новое задание',
                  subtitle: capabilitiesLoading
                      ? 'Проверяем права…'
                      : (proposeEnabled
                          ? 'Чтобы появилось у всех — нужны 2 голоса'
                          : (proposeDisabledReason ?? 'Недоступно')),
                  emphasized: true,
                  enabled: proposeEnabled && !capabilitiesLoading,
                  loading: capabilitiesLoading,
                  onTap: () async {
                    final res = await showAssignmentFormDialog(context);
                    if (res == null) return;
                    await onPropose(res.$1, res.$2, res.$3, res.$4, res.$5);
                  },
                ),
              if (showTopicSelectionInPlus)
                ChatPlusAction(
                  icon: Icons.format_list_numbered_rtl,
                  title: 'Выбор темы',
                  subtitle: capabilitiesLoading
                      ? 'Проверяем права…'
                      : (topicSelectionEnabled
                          ? 'Список тем для распределения по предмету'
                          : (topicSelectionDisabledReason ?? 'Недоступно')),
                  enabled: topicSelectionEnabled && !capabilitiesLoading,
                  loading: capabilitiesLoading,
                  onTap: () async {
                    onOpenTopicSelection?.call();
                  },
                ),
              if (showCollectionInPlus)
                ChatPlusAction(
                  icon: Icons.volunteer_activism_outlined,
                  title: 'Скинуться',
                  subtitle: capabilitiesLoading
                      ? 'Проверяем права…'
                      : (collectionEnabled
                          ? 'Организация взноса (без оплаты в приложении)'
                          : (collectionDisabledReason ?? 'Недоступно')),
                  enabled: collectionEnabled && !capabilitiesLoading,
                  loading: capabilitiesLoading,
                  onTap: () async {
                    onOpenCollection?.call();
                  },
                ),
              if (showFindInPlus)
                ChatPlusAction(
                  icon: Icons.search,
                  title: 'Поиск по чату',
                  subtitle: 'Найти сообщение в текущей переписке',
                  onTap: onFind,
                ),
            ],
          ),
          isUploading: isUploading,
          hasFailedUploads: hasFailedUploads,
          isSending: isSending,
        ),
      ],
    );
  }

  String _replyAuthor(Message message) {
    final name = message.authorName.trim();
    if (name.isNotEmpty) return name;
    return message.isMine(null) ? 'Вы' : 'Сообщение';
  }

  IconData _replyIcon(Message message) {
    if (message.type == MessageType.assignmentDraft ||
        message.type == MessageType.assignmentPublished) {
      return Icons.assignment_outlined;
    }
    final attachments = message.attachments ?? const [];
    if (attachments.any((file) => file.isImage)) return Icons.image_outlined;
    if (attachments.isNotEmpty || message.type == MessageType.file) {
      return Icons.insert_drive_file_outlined;
    }
    return Icons.reply;
  }

  String _replyPreview(Message message) {
    final text = message.text.trim();
    if (text.isNotEmpty) return text;

    if (message.type == MessageType.assignmentDraft ||
        message.type == MessageType.assignmentPublished) {
      return 'Задание';
    }

    final attachments = message.attachments ?? const [];
    if (attachments.isEmpty) return 'Сообщение';
    final firstName = attachments.first.fileName.trim();
    final name = firstName.isNotEmpty
        ? firstName
        : (attachments.first.isImage ? 'Изображение' : 'Файл');
    if (attachments.length == 1) return name;
    return '$name +${attachments.length - 1}';
  }
}
