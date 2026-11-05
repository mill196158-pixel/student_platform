import 'package:flutter/material.dart';

const _options = [
  (
    mode: ThemeMode.system,
    label: 'Как на устройстве',
    icon: Icons.brightness_auto_outlined,
  ),
  (
    mode: ThemeMode.light,
    label: 'Светлая',
    icon: Icons.light_mode_outlined,
  ),
  (
    mode: ThemeMode.dark,
    label: 'Тёмная',
    icon: Icons.dark_mode_outlined,
  ),
];

String themeModeLabel(ThemeMode mode) =>
    _options.firstWhere((option) => option.mode == mode).label;

Future<ThemeMode?> showThemeModePicker(BuildContext context, ThemeMode current) {
  if (MediaQuery.sizeOf(context).width >= 600) {
    return showDialog<ThemeMode>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        constraints: const BoxConstraints(maxWidth: 420),
        child: _ThemeModePicker(current: current),
      ),
    );
  }
  return showModalBottomSheet<ThemeMode>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      top: false,
      child: _ThemeModePicker(current: current),
    ),
  );
}

class _ThemeModePicker extends StatelessWidget {
  const _ThemeModePicker({required this.current});

  final ThemeMode current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 6),
            child: Row(
              children: [
                Expanded(child: Text('Тема', style: theme.textTheme.titleLarge)),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (final option in _options)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                minTileHeight: 52,
                leading: Icon(option.icon),
                title: Text(option.label),
                selected: option.mode == current,
                autofocus: option.mode == current,
                selectedColor: colors.onPrimaryContainer,
                selectedTileColor: colors.primaryContainer,
                trailing: option.mode == current
                    ? const Icon(Icons.check_rounded, size: 20)
                    : null,
                onTap: () => Navigator.of(context).pop(option.mode),
              ),
            ),
        ],
      ),
    );
  }
}
