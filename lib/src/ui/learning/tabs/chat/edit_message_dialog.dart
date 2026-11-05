import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
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

/// Calls [onSave] while keeping the editor open and blocking repeat taps.
Future<bool> showEditMessageDialog(
  BuildContext context, {
  required String initialText,
  required Future<void> Function(String text) onSave,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _EditMessageDialog(initialText: initialText, onSave: onSave),
    ) ??
    false;

class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({required this.initialText, required this.onSave});
  final String initialText;
  final Future<void> Function(String text) onSave;
  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _controller;
  bool _saving = false;
  String? _localError;
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.selection =
        TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _localError = 'Текст не может быть пустым');
      return;
    }
    if (text.length > kChatMessageMaxLength) {
      setState(() => _localError = 'Слишком длинный текст');
      return;
    }
    if (text == widget.initialText.trim()) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _saving = true;
      _localError = null;
    });
    try {
      await widget.onSave(text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error, stack) {
      debugPrint('[editOwnMessage] $error\n$stack');
      if (!mounted) return;
      setState(() {
        _saving = false;
        _localError = friendlyEditMessageError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        title: const Text('Изменить сообщение'),
        content: SizedBox(
            width: 440,
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                      controller: _controller,
                      autofocus: true,
                      maxLines: 6,
                      minLines: 2,
                      maxLength: kChatMessageMaxLength,
                      enabled: !_saving,
                      decoration:
                          const InputDecoration(hintText: 'Текст сообщения'),
                      onSubmitted: (_) => _submit()),
                  if (_localError != null) ...[
                    const SizedBox(height: 12),
                    Text(_localError!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ])),
        actions: [
          TextButton(
              onPressed:
                  _saving ? null : () => Navigator.of(context).pop(false),
              child: const Text('Отмена')),
          FilledButton(
              onPressed: _saving ? null : _submit,
              child: _saving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: ProductLoadingIndicator(
                          color: Theme.of(context).colorScheme.onPrimary))
                  : const Text('Сохранить')),
        ],
      );
}
