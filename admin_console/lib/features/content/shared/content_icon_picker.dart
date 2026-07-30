import 'package:flutter/material.dart';

import 'content_icon_catalog.dart';

/// Opens a modal dialog and returns the selected icon key, or null if cleared.
Future<String?> showContentIconPickerDialog({
  required BuildContext context,
  String? selectedKey,
  Color? previewColor,
}) {
  return showDialog<String?>(
    context: context,
    builder: (dialogContext) => _ContentIconPickerDialog(
      selectedKey: selectedKey,
      previewColor: previewColor,
    ),
  );
}

/// Inline field that opens the icon picker dialog.
class ContentIconPickerField extends StatelessWidget {
  const ContentIconPickerField({
    required this.selectedKey,
    required this.onChanged,
    this.enabled = true,
    this.previewColor,
    super.key,
  });

  final String? selectedKey;
  final ValueChanged<String?> onChanged;
  final bool enabled;
  final Color? previewColor;

  @override
  Widget build(BuildContext context) {
    final entry = contentIconEntryForKey(selectedKey);
    final iconData = entry?.iconData ?? Icons.image_outlined;
    final label = entry?.labelRu ?? 'Без иконки';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Иконка', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: !enabled
              ? null
              : () async {
                  final picked = await showContentIconPickerDialog(
                    context: context,
                    selectedKey: selectedKey,
                    previewColor: previewColor,
                  );
                  if (picked != selectedKey) onChanged(picked);
                },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconData, color: previewColor ?? const Color(0xFF6656D9)),
              const SizedBox(width: 10),
              Flexible(child: Text(label)),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, size: 20),
            ],
          ),
        ),
      ],
    );
  }
}

class _ContentIconPickerDialog extends StatefulWidget {
  const _ContentIconPickerDialog({this.selectedKey, this.previewColor});

  final String? selectedKey;
  final Color? previewColor;

  @override
  State<_ContentIconPickerDialog> createState() =>
      _ContentIconPickerDialogState();
}

class _ContentIconPickerDialogState extends State<_ContentIconPickerDialog> {
  late String? _selectedKey;
  String _query = '';
  ContentIconCategory? _categoryFilter;

  @override
  void initState() {
    super.initState();
    _selectedKey = widget.selectedKey;
  }

  List<ContentIconEntry> get _visibleIcons {
    var list = searchContentIconsByRuName(_query);
    if (_categoryFilter != null) {
      list = list.where((e) => e.category == _categoryFilter).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final previewColor = widget.previewColor ?? const Color(0xFF6656D9);

    return AlertDialog(
      title: const Text('Выбор иконки'),
      content: SizedBox(
        width: 480,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: 'Поиск',
                hintText: 'Название на русском',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: const Text('Все'),
                      selected: _categoryFilter == null,
                      onSelected: (_) => setState(() => _categoryFilter = null),
                    ),
                  ),
                  for (final category in contentIconCategories)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(category.labelRu),
                        selected: _categoryFilter == category,
                        onSelected: (_) =>
                            setState(() => _categoryFilter = category),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 6,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: _visibleIcons.length,
                itemBuilder: (context, index) {
                  final entry = _visibleIcons[index];
                  final selected = entry.key == _selectedKey;
                  return Tooltip(
                    message: entry.labelRu,
                    child: InkWell(
                      onTap: () => setState(() => _selectedKey = entry.key),
                      borderRadius: BorderRadius.circular(12),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: selected
                              ? Theme.of(context).colorScheme.primaryContainer
                              : const Color(0xFFF4F5FA),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected
                                ? Theme.of(context).colorScheme.primary
                                : const Color(0xFFD8DCE8),
                            width: selected ? 2 : 1,
                          ),
                        ),
                        child: Icon(entry.iconData, color: previewColor),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Без иконки'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedKey),
          child: const Text('Выбрать'),
        ),
      ],
    );
  }
}
