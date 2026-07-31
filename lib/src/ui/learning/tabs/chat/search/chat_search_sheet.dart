import 'package:flutter/material.dart';
import 'chat_search_controller.dart';

class ChatSearchSheet extends StatefulWidget {
  final ChatSearchController controller;
  final VoidCallback onClose;

  const ChatSearchSheet({
    Key? key,
    required this.controller,
    required this.onClose,
  }) : super(key: key);

  @override
  State<ChatSearchSheet> createState() => _ChatSearchSheetState();
}

class _ChatSearchSheetState extends State<ChatSearchSheet> {
  @override
  Widget build(BuildContext context) {
    final int total = widget.controller.total.value;
    final int idx = widget.controller.index.value;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Поиск сообщений',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            TextField(
              controller: widget.controller.field,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Текст, автор, файл, время (HH:MM)',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (widget.controller.matches.isNotEmpty) {
                  widget.controller.next();
                  setState(() {});
                }
              },
            ),
            const SizedBox(height: 10),
            Text(total == 0
                ? 'Совпадений: 0'
                : 'Совпадений: $total  •  Текущая: $idx'),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                ElevatedButton(
                  onPressed: widget.controller.matches.isEmpty
                      ? null
                      : () {
                          widget.controller.prev();
                          setState(() {});
                        },
                  child: const Text('Назад'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: widget.controller.matches.isEmpty
                      ? null
                      : () {
                          widget.controller.next();
                          setState(() {});
                        },
                  child: const Text('Вперёд'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: widget.onClose,
                  child: const Text('Закрыть'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
