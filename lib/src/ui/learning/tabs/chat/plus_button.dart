import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class PlusButton extends StatelessWidget {
  final void Function(String text)? onPinText;
  final Future<void> Function(
    String title,
    String description,
    String? link,
    String? due,
    List<Map<String, String>> attachments,
  )? onPropose;

  const PlusButton({super.key, this.onPinText, this.onPropose});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.add_circle_outline),
      onPressed: () async {
        showModalBottomSheet(
          context: context,
          showDragHandle: true,
          builder: (_) => SafeArea(
            child: Wrap(
              children: [
                ListTile(
                  leading: const Icon(Icons.post_add_outlined),
                  title: const Text('Предложить задание'),
                  onTap: () async {
                    Navigator.pop(context);
                    final res = await _askAssignment(context);
                    if (res == null) return;
                    await onPropose?.call(res.$1, res.$2, res.$3, res.$4, res.$5);
                  },
                ),
                if (onPinText != null)
                  ListTile(
                    leading: const Icon(Icons.push_pin_outlined),
                    title: const Text('Закрепить заметку'),
                    onTap: () async {
                      Navigator.pop(context);
                      final txt = await _askText(context);
                      if (txt != null && txt.trim().isNotEmpty) onPinText!(txt.trim());
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<String?> _askText(BuildContext context) async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Center(child: Text('Закрепить заметку', style: TextStyle(fontWeight: FontWeight.w700))),
        content: TextField(controller: c, maxLines: 3, decoration: const InputDecoration(hintText: 'Текст заметки')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Закрепить')),
        ],
      ),
    );
  }

  Future<(String, String, String?, String?, List<Map<String, String>>)?> _askAssignment(
      BuildContext context) async {
    final title = TextEditingController();
    final desc = TextEditingController();
    final link = TextEditingController();
    final due = TextEditingController();
    final List<Map<String, String>> files = [];

    return showDialog<(String, String, String?, String?, List<Map<String, String>>)>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Center(
            child: Text('Новое задание', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700)),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Название')),
                const SizedBox(height: 8),
                TextField(
                  controller: desc, minLines: 3, maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Что сделать'),
                ),
                const SizedBox(height: 8),
                TextField(controller: link, decoration: const InputDecoration(labelText: 'Ссылка (опц.)')),
                const SizedBox(height: 8),
                TextField(
                  controller: due,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: 'Срок',
                    hintText: 'Выберите дату',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.calendar_today_outlined),
                      onPressed: () async {
                        final now = DateTime.now();
                        final picked = await showDatePicker(
                          context: context,
                          firstDate: now,
                          lastDate: DateTime(now.year + 2),
                          initialDate: now,
                        );
                        if (picked != null) {
                          due.text =
                              '${picked.day.toString().padLeft(2, '0')}.${picked.month.toString().padLeft(2, '0')}';
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () async {
                      final res = await ImagePicker().pickImage(source: ImageSource.gallery);
                      if (res != null) {
                        setState(() => files.add({'name': res.name, 'path': res.path}));
                      }
                    },
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Вложить файл/изображение'),
                  ),
                ),
                for (final f in files)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(f['name'] ?? ''),
                    subtitle: Text(f['path'] ?? ''),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            FilledButton(
              onPressed: () {
                if (title.text.trim().isEmpty || desc.text.trim().isEmpty) return;
                Navigator.pop(
                  context,
                  (
                    title.text.trim(),
                    desc.text.trim(),
                    link.text.trim().isEmpty ? null : link.text.trim(),
                    due.text.trim().isEmpty ? null : due.text.trim(),
                    files,
                  ),
                );
              },
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
  }
}
