import 'dart:ui';
import 'package:flutter/material.dart';

class TopSelectionBar extends StatelessWidget {
  final VoidCallback onCancel;
  final int count;
  const TopSelectionBar({
    super.key,
    required this.onCancel,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 126,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              top: 56,
              left: 0,
              right: 0,
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 160),
                      child: Container(
                        key: ValueKey(count),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 22, vertical: 11),
                        decoration: BoxDecoration(
                          color: cs.surface.withValues(alpha: .72),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: .34),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: .14),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Text(
                          'Выбрано $count',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: cs.onSurface,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              top: 50,
              child: Material(
                color: cs.primary,
                shape: const CircleBorder(),
                elevation: 8,
                shadowColor: Colors.black.withValues(alpha: .22),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onCancel,
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.check_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BottomSelectionBar extends StatelessWidget {
  final VoidCallback? onForward;
  final VoidCallback? onDelete;
  const BottomSelectionBar(
      {super.key, required this.onForward, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _SelectionBottomAction(
              icon: Icons.delete_outline_rounded,
              label: 'Удалить',
              color: cs.error,
              enabled: onDelete != null,
              onTap: onDelete,
            ),
            _SelectionBottomAction(
              icon: Icons.shortcut_rounded,
              label: 'Переслать',
              color: cs.primary,
              enabled: onForward != null,
              onTap: onForward,
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectionBottomAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback? onTap;

  const _SelectionBottomAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = enabled ? color : theme.colorScheme.outlineVariant;

    return Opacity(
      opacity: enabled ? 1 : .48,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: .88),
                  shape: BoxShape.circle,
                  border: Border.all(color: effective.withValues(alpha: .18)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .12),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Icon(icon, color: effective, size: 23),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
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
