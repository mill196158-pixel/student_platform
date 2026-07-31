import 'package:flutter/material.dart';
import 'chat_search_controller.dart';

class InlineSearchBar extends StatelessWidget {
  final ChatSearchController controller;
  final VoidCallback onClose;

  const InlineSearchBar({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: .75),
          width: .8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller.field,
              autofocus: true,
              cursorColor: cs.primary,
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: 'Текст, автор, файл, время (HH:MM)',
                hintStyle: TextStyle(
                  color: cs.onSurfaceVariant.withValues(alpha: .78),
                  fontWeight: FontWeight.w500,
                ),
              ),
              onSubmitted: (_) => controller.next(),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<int>(
            valueListenable: controller.total,
            builder: (_, total, __) => ValueListenableBuilder<int>(
              valueListenable: controller.index,
              builder: (_, idx, __) => Text(
                total == 0 ? '0' : '$idx/$total',
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          // Вверх → следующий (вниз по ленте)
          IconButton(
            tooltip: 'Вперёд',
            icon: Icon(Icons.keyboard_arrow_up, color: cs.onSurfaceVariant),
            onPressed: controller.matches.isEmpty ? null : controller.next,
          ),
          // Вниз → предыдущий (вверх по ленте)
          IconButton(
            tooltip: 'Назад',
            icon: Icon(Icons.keyboard_arrow_down, color: cs.onSurfaceVariant),
            onPressed: controller.matches.isEmpty ? null : controller.prev,
          ),
          IconButton(
            tooltip: 'Закрыть',
            icon: Icon(Icons.close, color: cs.onSurfaceVariant),
            onPressed: () {
              // Закрываем немедленно: скрыть клавиатуру, очистить, деактивировать, скрыть бар
              FocusScope.of(context).unfocus();
              controller.clear();
              controller.setActive(false);
              onClose();
            },
          ),
        ],
      ),
    );
  }
}
