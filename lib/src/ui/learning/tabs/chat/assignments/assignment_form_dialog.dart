import 'package:flutter/material.dart';

import '../../../models/assignment.dart';

typedef AssignmentFormResult = (
  String title,
  String description,
  String? link,
  String? due,
  List<Map<String, String>> attachments,
);

Future<AssignmentFormResult?> showAssignmentFormDialog(
  BuildContext context, {
  Assignment? initial,
}) {
  final title = TextEditingController(text: initial?.title ?? '');
  final desc = TextEditingController(text: initial?.description ?? '');
  final link = TextEditingController(text: initial?.link ?? '');
  final due = TextEditingController(text: initial?.due ?? '');
  final files = <Map<String, String>>[...?initial?.attachments];
  final formKey = GlobalKey<FormState>();

  return showModalBottomSheet<AssignmentFormResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final theme = Theme.of(context);
          final viewInsets = MediaQuery.viewInsetsOf(context);
          final colorScheme = theme.colorScheme;
          final textTheme = theme.textTheme;
          final isEditing = initial != null;

          Future<void> pickDueDate() async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              firstDate: DateTime(now.year - 1),
              lastDate: DateTime(now.year + 2),
              initialDate: now,
            );
            if (picked == null) return;
            if (!context.mounted) return;
            due.text =
                '${picked.day.toString().padLeft(2, '0')}.${picked.month.toString().padLeft(2, '0')}';
            setState(() {});
          }

          void submit() {
            if (!(formKey.currentState?.validate() ?? false)) return;
            Navigator.pop(sheetContext, (
              title.text.trim(),
              desc.text.trim(),
              link.text.trim().isEmpty ? null : link.text.trim(),
              due.text.trim().isEmpty ? null : due.text.trim(),
              files,
            ));
          }

          return Padding(
            padding: EdgeInsets.only(bottom: viewInsets.bottom),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Material(
                  color: colorScheme.surface,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                    child: Form(
                      key: formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 42,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 18),
                              decoration: BoxDecoration(
                                color: colorScheme.outlineVariant,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(
                                  isEditing
                                      ? Icons.edit_note
                                      : Icons.assignment_add,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isEditing
                                          ? 'Редактировать задание'
                                          : 'Новое задание',
                                      style: textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.w800),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      isEditing
                                          ? 'Обнови формулировку, срок и материалы'
                                          : 'Коротко, понятно и без лишнего шума в чате',
                                      style: textTheme.bodyMedium?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 22),
                          TextFormField(
                            controller: title,
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Название',
                              hintText: 'Например: Практика по интегралам',
                              prefixIcon: Icon(Icons.title),
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) => (value ?? '').trim().isEmpty
                                ? 'Добавь название задания'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: desc,
                            minLines: 4,
                            maxLines: 8,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              labelText: 'Что сделать',
                              hintText:
                                  'Опиши задачу, формат сдачи и важные условия',
                              prefixIcon: Icon(Icons.notes),
                              alignLabelWithHint: true,
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) => (value ?? '').trim().isEmpty
                                ? 'Опиши, что нужно сделать'
                                : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: link,
                            keyboardType: TextInputType.url,
                            decoration: const InputDecoration(
                              labelText: 'Ссылка',
                              hintText: 'Необязательно',
                              prefixIcon: Icon(Icons.link),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: pickDueDate,
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Срок',
                                prefixIcon: Icon(Icons.event_outlined),
                                border: OutlineInputBorder(),
                              ),
                              child: Text(
                                due.text.isEmpty ? 'Не выбран' : due.text,
                                style: TextStyle(
                                  color: due.text.isEmpty
                                      ? colorScheme.onSurfaceVariant
                                      : colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                          if (files.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text('Вложения',
                                style: textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            for (final file in files)
                              Card(
                                elevation: 0,
                                color: colorScheme.surfaceContainerHighest
                                    .withValues(alpha: .55),
                                child: ListTile(
                                  dense: true,
                                  leading: const Icon(
                                      Icons.insert_drive_file_outlined),
                                  title: Text(file['name'] ?? 'Файл'),
                                  subtitle: Text(
                                    file['path'] ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                          ],
                          const SizedBox(height: 22),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.pop(sheetContext),
                                  child: const Text('Отмена'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: submit,
                                  icon: Icon(isEditing
                                      ? Icons.save_outlined
                                      : Icons.add_task),
                                  label: Text(
                                      isEditing ? 'Сохранить' : 'Добавить'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(() {
    title.dispose();
    desc.dispose();
    link.dispose();
    due.dispose();
  });
}
