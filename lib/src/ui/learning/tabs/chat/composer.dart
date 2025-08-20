import 'dart:io';
import 'package:flutter/material.dart';

class Composer extends StatelessWidget {
  final TextEditingController controller;
  final String? pickedImagePath;
  final Widget? leftButton;
  final VoidCallback onOpenEmoji;     // открыть системную клавиатуру / фокус
  final VoidCallback onSend;
  final VoidCallback onClearPicked;
  final Future<void> Function() onPickImage;
  final FocusNode? focusNode;

  const Composer({
    super.key,
    required this.controller,
    required this.pickedImagePath,
    required this.onOpenEmoji,
    required this.onSend,
    required this.onClearPicked,
    required this.onPickImage,
    this.leftButton,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        // без хинтов/подписей снизу
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pickedImagePath != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.outline.withOpacity(.2)),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(pickedImagePath!),
                        height: 44,
                        width: 44,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('Вложение готово')),
                    IconButton(icon: const Icon(Icons.close), onPressed: onClearPicked),
                  ],
                ),
              ),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                leftButton ?? const SizedBox(width: 0),
                if (leftButton != null) const SizedBox(width: 8),

                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: theme.colorScheme.outline.withOpacity(.2)),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.emoji_emotions_outlined),
                          onPressed: onOpenEmoji, // просто открываем клавиатуру/даём фокус
                          tooltip: 'Эмодзи',
                        ),

                        // одна строка → авто-рост до 6 (без горизонтального скролла)
                        Expanded(
                          child: TextField(
                            focusNode: focusNode,
                            controller: controller,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.send, // Enter — отправка
                            minLines: 1,
                            maxLines: 6,
                            decoration: const InputDecoration(
                              hintText: 'Сообщение',
                              border: InputBorder.none,
                              isCollapsed: true,
                              contentPadding: EdgeInsets.symmetric(vertical: 12),
                            ),
                            onSubmitted: (_) => onSend(),
                          ),
                        ),

                        IconButton(
                          icon: const Icon(Icons.camera_alt_outlined),
                          onPressed: () => onPickImage(), // из галереи (gif поддерживаются как файл)
                          tooltip: 'Изображение',
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send_rounded),
                  onPressed: onSend,
                  tooltip: 'Отправить',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
