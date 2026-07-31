import 'package:flutter/material.dart';

class SearchHighlight extends StatelessWidget {
  final bool active;
  final bool isCurrent;
  final Widget child;
  final VoidCallback? onTap;

  const SearchHighlight({
    super.key,
    required this.active,
    required this.isCurrent,
    required this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!active) return child;

    final decorated = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: isCurrent ? Colors.amber.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: isCurrent
            ? Border.all(color: Colors.amber.withOpacity(0.6), width: 1)
            : null,
      ),
      child: child,
    );

    // В режиме поиска позволяем тапом центрировать текущее сообщение
    if (isCurrent && onTap != null) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        child: decorated,
      );
    }

    return decorated;
  }
}
