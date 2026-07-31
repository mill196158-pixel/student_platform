import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../common/keyboard_dismiss_scope.dart';

/// Result of the modern «Новая тема» / «Изменить тему» sheet.
class TopicOptionDraftResult {
  const TopicOptionDraftResult({
    required this.title,
    required this.capacity,
  });

  final String title;
  final int capacity;
}

/// Scroll-controlled bottom sheet for adding/editing a topic option.
Future<TopicOptionDraftResult?> showTopicOptionEditSheet(
  BuildContext context, {
  String initialTitle = '',
  int initialCapacity = 1,
  int minCapacity = 0,
  bool isNew = true,
}) {
  return showModalBottomSheet<TopicOptionDraftResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _TopicOptionEditSheet(
      initialTitle: initialTitle,
      initialCapacity: initialCapacity,
      minCapacity: minCapacity,
      isNew: isNew,
    ),
  );
}

class _TopicOptionEditSheet extends StatefulWidget {
  const _TopicOptionEditSheet({
    required this.initialTitle,
    required this.initialCapacity,
    required this.minCapacity,
    required this.isNew,
  });

  final String initialTitle;
  final int initialCapacity;
  final int minCapacity;
  final bool isNew;

  @override
  State<_TopicOptionEditSheet> createState() => _TopicOptionEditSheetState();
}

class _TopicOptionEditSheetState extends State<_TopicOptionEditSheet> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _capCtrl;
  String? _titleError;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.initialTitle);
    _capCtrl = TextEditingController(text: '${widget.initialCapacity}');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  InputDecoration _fieldDecoration({
    required String label,
    String? helper,
    String? error,
  }) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(14);
    return InputDecoration(
      labelText: label,
      helperText: helper,
      errorText: error,
      filled: true,
      fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.55),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: cs.primary, width: 1.4),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: cs.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: cs.error, width: 1.4),
      ),
    );
  }

  void _submit() {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = 'Введите название темы');
      return;
    }
    var capacity = int.tryParse(_capCtrl.text.trim()) ?? widget.initialCapacity;
    if (capacity < widget.minCapacity) capacity = widget.minCapacity;
    if (capacity < 1) capacity = 1;
    if (capacity > 999) capacity = 999;
    Navigator.of(context).pop(TopicOptionDraftResult(
      title: title,
      capacity: capacity,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Material(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: KeyboardDismissScope(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: cs.outlineVariant,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Text(
                    widget.isNew ? 'Новая тема' : 'Изменить тему',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.isNew
                        ? 'Добавьте название и число мест'
                        : 'Обновите название или число мест',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _titleCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) {
                      if (_titleError != null) {
                        setState(() => _titleError = null);
                      }
                    },
                    decoration: _fieldDecoration(
                      label: 'Название темы',
                      error: _titleError,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _capCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: _fieldDecoration(
                      label: 'Количество мест',
                      helper: widget.minCapacity > 0
                          ? 'Уже занято: ${widget.minCapacity}'
                          : 'Обычно 1 место на тему',
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      widget.isNew ? 'Добавить тему' : 'Сохранить',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
