import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composer.dart';

class TopSelectionBar extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback onClose;
  final int count;

  /// Team chat removes its top MediaQuery padding before building the header.
  final bool includeTopInset;

  const TopSelectionBar({
    super.key,
    required this.onClose,
    required this.count,
    this.includeTopInset = true,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  static double rawTopInset(BuildContext context) {
    final view = View.of(context);
    return view.padding.top / view.devicePixelRatio;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.surface,
      child: Padding(
        padding: EdgeInsets.only(
          top: includeTopInset ? rawTopInset(context) : 0,
        ),
        child: SizedBox(
          height: kToolbarHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Назад',
                  constraints:
                      const BoxConstraints.tightFor(width: 44, height: 44),
                  color: scheme.onSurface,
                  icon: const Icon(Icons.close_rounded, size: 23),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    onClose();
                  },
                ),
                Expanded(
                  child: Text(
                    'Выбрано $count',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 44),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class BottomSelectionBar extends StatelessWidget {
  final VoidCallback? onCopy;
  final VoidCallback? onForward;
  final VoidCallback? onDelete;
  final String? deleteUnavailableHint;
  final ValueChanged<String>? onUnavailable;

  const BottomSelectionBar({
    super.key,
    this.onCopy,
    required this.onForward,
    required this.onDelete,
    this.deleteUnavailableHint,
    this.onUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: Composer.restingHeightOf(context),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              4,
              6,
              4,
              Composer.bottomPaddingOf(context) + 4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: _SelectionAction(
                    icon: Icons.copy_rounded,
                    label: 'Копировать',
                    color: scheme.onSurface,
                    onTap: onCopy,
                    unavailableHint: 'Нечего копировать',
                    onUnavailable: onUnavailable,
                  ),
                ),
                Expanded(
                  child: _SelectionAction(
                    icon: Icons.shortcut_rounded,
                    label: 'Переслать',
                    color: scheme.primary,
                    onTap: onForward,
                    unavailableHint: 'Выберите сообщения',
                    onUnavailable: onUnavailable,
                  ),
                ),
                Expanded(
                  child: _SelectionAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'Удалить',
                    color: scheme.error,
                    onTap: onDelete,
                    unavailableHint: deleteUnavailableHint ??
                        'Удалить можно только свои сообщения не старше 12 часов',
                    onUnavailable: onUnavailable,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final String unavailableHint;
  final ValueChanged<String>? onUnavailable;

  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    required this.unavailableHint,
    required this.onUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final actionColor = onTap == null ? scheme.onSurfaceVariant : color;

    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          final action = onTap;
          if (action == null) {
            HapticFeedback.heavyImpact();
            onUnavailable?.call(unavailableHint);
          } else {
            HapticFeedback.lightImpact();
            action();
          }
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: actionColor, size: 21),
                const SizedBox(height: 3),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: actionColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
