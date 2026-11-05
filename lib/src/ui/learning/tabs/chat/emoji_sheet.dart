import 'package:student_ui/student_ui.dart' show ProductLoadingIndicator;
import 'package:flutter/material.dart';
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
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (sheetCtx) {
      final colors = Theme.of(sheetCtx).colorScheme;
      final media = MediaQuery.of(sheetCtx);
      final width = media.size.width.clamp(0.0, 600.0);
      return Padding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SizedBox(
            height: (media.size.height -
                    media.viewInsets.bottom -
                    media.padding.top -
                    60)
                .clamp(160.0, 420.0),
            child: Column(
              children: [
                // Верхняя панель действий (легкое переключение на клавиатуру)
                Row(
                  children: [
                    const SizedBox(width: 12),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Text('Эмодзи',
                          style: TextStyle(fontWeight: FontWeight.w600)),
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
                      final end = sel.end >= 0 ? sel.end : text.length;
                      controller.value = TextEditingValue(
                        text: text.replaceRange(start, end, emoji.emoji),
                        selection: TextSelection.collapsed(
                            offset: start + emoji.emoji.length),
                      );
                    },
                    config: Config(
                      height: null,
                      locale: const Locale('ru'),
                      bottomActionBarConfig: BottomActionBarConfig(
                          enabled: true,
                          backgroundColor: colors.surfaceContainerLow,
                          buttonColor: colors.surfaceContainerLow,
                          buttonIconColor: colors.primary),
                      emojiViewConfig: EmojiViewConfig(
                          emojiSizeMax: 28,
                          columns: (width / 48).floor().clamp(5, 10),
                          backgroundColor: colors.surface,
                          noRecents: Text('Здесь появятся недавние эмодзи',
                              textAlign: TextAlign.center,
                              style: Theme.of(sheetCtx).textTheme.bodySmall),
                          loadingIndicator:
                              const Center(child: ProductLoadingIndicator())),
                      categoryViewConfig: CategoryViewConfig(
                        tabBarHeight: 48,
                        backgroundColor: colors.surface,
                        indicatorColor: colors.primary,
                        iconColor: colors.onSurfaceVariant,
                        iconColorSelected: colors.primary,
                        backspaceColor: colors.primary,
                        dividerColor: colors.outlineVariant,
                      ),
                      searchViewConfig: SearchViewConfig(
                          backgroundColor: colors.surface,
                          buttonIconColor: colors.primary,
                          hintText: 'Поиск эмодзи',
                          inputTextStyle:
                              Theme.of(sheetCtx).textTheme.bodyMedium,
                          hintTextStyle: Theme.of(sheetCtx)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant)),
                    ),
                  ),
                ),
              ],
            ),
          ));
    },
  );
}
