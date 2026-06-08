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

  final bool someoneTyping;
  final List<String> typingNames;

  final List<AttachedFile> attachedFiles;

  final VoidCallback onSend;
  final Future<void> Function() onPickImage;
  final VoidCallback onOpenEmoji;
  final Future<void> Function()? onAttachFile;
  final void Function(AttachedFile file) onRemoveFile;
  final void Function(AttachedFile file) onAddFile;

  final void Function(String text) onPinText;
  final Future<void> Function() onFind;
  final Future<void> Function(String title, String description, String? link, String? due, List<Map<String,String>> attachments) onPropose;

  // Controls for showing actions in the plus menu; default true to not break callers
  final bool showFindInPlus;
  final bool showProposeInPlus;

  // sending/upload state to control send button
  final bool isUploading;
  final bool isSending;

  const ChatComposerBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.replyTo,
    required this.onCloseReply,
    required this.someoneTyping,
    required this.typingNames,
    required this.attachedFiles,
    required this.onSend,
    required this.onPickImage,
    required this.onOpenEmoji,
    required this.onAttachFile,
    required this.onRemoveFile,
    required this.onAddFile,
    required this.onPinText,
    required this.onFind,
    required this.onPropose,
    this.showFindInPlus = true,
    this.showProposeInPlus = true,
    this.isUploading = false,
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
              border: Border.all(color: themed.colorScheme.outline.withValues(alpha: .25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.reply, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(replyTo!.text, maxLines: 2, overflow: TextOverflow.ellipsis)),
                IconButton(icon: const Icon(Icons.close), onPressed: onCloseReply),
              ],
            ),
          ),

        if (someoneTyping) TypingLine(names: typingNames),

        Composer(
          controller: controller,
          focusNode: focusNode,
          pickedImagePath: null,
          attachedFiles: attachedFiles,
          onAddFile: onAddFile,
          onRemoveFile: onRemoveFile,
          onOpenEmoji: onOpenEmoji,
          onSend: onSend,
          onClearPicked: () {},
          onPickImage: onPickImage,
          onAttachFile: onAttachFile,
          leftButton: ChatPlusButton(
            actions: [
              if (showProposeInPlus)
                ChatPlusAction(
                  icon: Icons.assignment_add,
                  title: 'Новое задание',
                  subtitle: 'Оформить задачу красиво и отправить в чат',
                  emphasized: true,
                  onTap: () async {
                    final res = await showAssignmentFormDialog(context);
                    if (res == null) return;
                    await onPropose(res.$1, res.$2, res.$3, res.$4, res.$5);
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
          isSending: isSending,
        ),
      ],
    );
  }
}
