import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/message.dart';

/// Max length aligned with public.edit_own_message.
const int kChatMessageMaxLength = 4096;

bool canEditOwnTextMessage(Message m, String? currentUserId) {
  if (currentUserId == null || currentUserId.isEmpty) return false;
  if (m.authorId != currentUserId) return false;
  if (m.isSystem || m.isLocal) return false;
  if (m.type != MessageType.text) return false;
  if (m.forward != null) return false;
  if (m.text.contains('__FG__:')) return false;
  if (m.attachments != null && m.attachments!.isNotEmpty) return false;
  if (m.text.trim().isEmpty) return false;
  return DateTime.now().difference(m.at) <= const Duration(hours: 12);
}

String friendlyEditMessageError(Object error) {
  final raw = error is PostgrestException
      ? (error.message.isNotEmpty ? error.message : error.code ?? '')
      : error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('not_authenticated')) {
    return 'Нужно войти в аккаунт';
  }
  if (lower.contains('message_not_found')) {
    return 'Сообщение не найдено';
  }
  if (lower.contains('not_author')) {
    return 'Можно менять только свои сообщения';
  }
  if (lower.contains('not_editable_type')) {
    return 'Этот тип сообщения нельзя изменить';
  }
  if (lower.contains('edit_window_expired')) {
    return 'Редактирование доступно 12 часов';
  }
  if (lower.contains('empty_text')) {
    return 'Текст не может быть пустым';
  }
  if (lower.contains('text_too_long')) {
    return 'Слишком длинный текст';
  }
  return 'Не удалось изменить сообщение';
}

/// Compact editor. Calls [onSave] while keeping the dialog open and
/// blocking repeat taps until the request finishes.
Future<bool> showEditMessageDialog(
  BuildContext context, {
  required String initialText,
  required Future<void> Function(String text) onSave,
}) async {
  final controller = TextEditingController(text: initialText);
  controller.selection = TextSelection(
    baseOffset: 0,
    extentOffset: controller.text.length,
  );

  final saved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          var saving = false;
          String? localError;
          return StatefulBuilder(
            builder: (ctx, setLocal) {
              Future<void> submit() async {
                if (saving) return;
                final text = controller.text.trim();
                if (text.isEmpty) {
                  setLocal(() => localError = 'Текст не может быть пустым');
                  return;
                }
                if (text.length > kChatMessageMaxLength) {
                  setLocal(() => localError = 'Слишком длинный текст');
                  return;
                }
                if (text == initialText.trim()) {
                  Navigator.of(ctx).pop(false);
                  return;
                }

                setLocal(() {
                  saving = true;
                  localError = null;
                });
                try {
                  await onSave(text);
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } catch (e, st) {
                  debugPrint('[editOwnMessage] $e\n$st');
                  if (!ctx.mounted) return;
                  setLocal(() {
                    saving = false;
                    localError = friendlyEditMessageError(e);
                  });
                }
              }

              return AlertDialog(
                title: const Text('Изменить сообщение'),
                content: SizedBox(
                  width: 360,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: controller,
                        autofocus: true,
                        maxLines: 6,
                        minLines: 2,
                        maxLength: kChatMessageMaxLength,
                        enabled: !saving,
                        decoration: const InputDecoration(
                          hintText: 'Текст сообщения',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => submit(),
                      ),
                      if (localError != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          localError!,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed:
                        saving ? null : () => Navigator.of(ctx).pop(false),
                    child: const Text('Отмена'),
                  ),
                  FilledButton(
                    onPressed: saving ? null : submit,
                    child: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Сохранить'),
                  ),
                ],
              );
            },
          );
        },
      ) ??
      false;

  controller.dispose();
  return saved;
}
