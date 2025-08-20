import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';

/// Модальное окно с эмодзи (современный UX):
/// - сверху панель с кнопкой «клавиатура» — закрывает модалку и сразу фокусит поле ввода;
/// - эмодзи вставляются именно в позицию курсора.
void showEmojiPickerSheet(
  BuildContext context, {
  required TextEditingController controller,
  FocusNode? textFieldFocus, // чтобы вернуть клавиатуру по кнопке
}) {
  showModalBottomSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) => SizedBox(
      height: 340,
      child: Column(
        children: [
          // Верхняя панель действий (легкое переключение на клавиатуру)
          Row(
            children: [
              const SizedBox(width: 12),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('Эмодзи', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Клавиатура',
                onPressed: () {
                  Navigator.pop(sheetCtx);
                  // вернуть фокус в поле; клавиатура поднимется сама
                  if (textFieldFocus != null) {
                    // чутка отложим, чтобы модалка успела закрыться
                    Future.microtask(() => textFieldFocus.requestFocus());
                  }
                },
                icon: const Icon(Icons.keyboard_alt_outlined),
              ),
            ],
          ),
          const Divider(height: 0),

          // Сам пикер
          Expanded(
            child: EmojiPicker(
              onEmojiSelected: (_, emoji) {
                final sel = controller.selection;
                final text = controller.text;
                final start = sel.start >= 0 ? sel.start : text.length;
                final end   = sel.end   >= 0 ? sel.end   : text.length;
                controller.value = TextEditingValue(
                  text: text.replaceRange(start, end, emoji.emoji),
                  selection: TextSelection.collapsed(offset: start + emoji.emoji.length),
                );
              },
              config: const Config(
                bottomActionBarConfig: BottomActionBarConfig(enabled: true),
                emojiViewConfig: EmojiViewConfig(emojiSizeMax: 32),
                categoryViewConfig: CategoryViewConfig(
                  indicatorColor: Colors.grey,
                  iconColorSelected: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
