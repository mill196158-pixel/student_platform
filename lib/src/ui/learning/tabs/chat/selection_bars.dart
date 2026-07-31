import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Верхняя панель режима выбора в духе Telegram:
/// слева «назад» (выход из выбора), по центру «Выбрано N».
class TopSelectionBar extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback onClose;
  final int count;

  /// Если true — сам учитывает status bar (нужно в team chat после removePadding).
  /// Если false — родитель уже дал safe-area (например обычный [AppBar]).
  final bool includeTopInset;

  const TopSelectionBar({
    super.key,
    required this.onClose,
    required this.count,
    this.includeTopInset = true,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  /// Safe-area top даже если родитель сделал [MediaQuery.removePadding]:
  /// тот обнуляет и `viewPadding.top`, поэтому читаем inset из FlutterView.
  static double rawTopInset(BuildContext context) {
    final view = View.of(context);
    return view.padding.top / view.devicePixelRatio;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final topInset = includeTopInset ? rawTopInset(context) : 0.0;

    return Material(
      color: theme.colorScheme.surface,
      elevation: 0,
      child: Padding(
        padding: EdgeInsets.only(top: topInset + (includeTopInset ? 8 : 0)),
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                _SelectionPillButton(
                  tooltip: 'Назад',
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onClose();
                  },
                  child: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Center(
                    child: _SelectionPill(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 140),
                        child: Text(
                          'Выбрано $count',
                          key: ValueKey(count),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Баланс ширины под кнопку «назад», без второй «Отмены».
                const SizedBox(width: 44),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionPill extends StatelessWidget {
  final Widget child;

  const _SelectionPill({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF2F2F7),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: child,
    );
  }
}

class _SelectionPillButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  final String tooltip;

  const _SelectionPillButton({
    required this.child,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xFFF2F2F7),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Container(
            width: 44,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Нижняя панель действий режима выбора (вместо композера).
/// Кнопки всегда читаемые; недоступные действия дают тактильный отказ
/// и вызывают [onUnavailable], а не «серые призраки».
class BottomSelectionBar extends StatelessWidget {
  final VoidCallback? onCopy;
  final VoidCallback? onForward;
  final VoidCallback? onDelete;

  /// Пояснение, если удаление недоступно (показывается через [onUnavailable]).
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Material(
      color: cs.surface,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: _SelectionAction(
                    icon: Icons.copy_rounded,
                    label: 'Копировать',
                    color: cs.onSurface,
                    enabled: onCopy != null,
                    onTap: onCopy,
                    onUnavailable: () => onUnavailable?.call(
                      'Нечего копировать',
                    ),
                  ),
                ),
                Expanded(
                  child: _SelectionAction(
                    icon: Icons.shortcut_rounded,
                    label: 'Переслать',
                    color: cs.primary,
                    enabled: onForward != null,
                    onTap: onForward,
                    onUnavailable: () => onUnavailable?.call(
                      'Выберите сообщения',
                    ),
                  ),
                ),
                Expanded(
                  child: _SelectionAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'Удалить',
                    color: cs.error,
                    enabled: onDelete != null,
                    onTap: onDelete,
                    onUnavailable: () => onUnavailable?.call(
                      deleteUnavailableHint ??
                          'Удалить можно только свои сообщения не старше 12 часов',
                    ),
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
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onUnavailable;

  const _SelectionAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    this.onTap,
    this.onUnavailable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = enabled ? color : theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: () {
        if (enabled && onTap != null) {
          HapticFeedback.lightImpact();
          onTap!();
          return;
        }
        HapticFeedback.heavyImpact();
        onUnavailable?.call();
      },
      borderRadius: BorderRadius.circular(14),
      child: Opacity(
        opacity: enabled ? 1 : 0.42,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: effective, size: 26),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: effective,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
