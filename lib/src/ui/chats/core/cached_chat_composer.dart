import 'package:flutter/material.dart';

/// Read-only offline composer. Its caller supplies any authorized saved text.
class CachedChatComposer extends StatelessWidget {
  const CachedChatComposer({super.key, this.draftText});

  final String? draftText;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Semantics(label: 'Отправка сообщений недоступна без сети', enabled: false,
        child: Row(children: [
          const IconButton(onPressed: null, icon: Icon(Icons.add_circle_outline)),
          Expanded(child: TextFormField(key: ValueKey(draftText), initialValue: draftText, enabled: false, decoration: InputDecoration(
            hintText: 'Сообщение', filled: true,
            fillColor: colors.surfaceContainerHighest,
            suffixIcon: const Icon(Icons.attach_file),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)))),
          const IconButton(onPressed: null, icon: Icon(Icons.arrow_upward)),
        ]))));
  }
}
