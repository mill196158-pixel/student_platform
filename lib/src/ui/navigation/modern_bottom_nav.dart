import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ModernBottomNavItem {
  final IconData icon;
  final String label;

  const ModernBottomNavItem({
    required this.icon,
    required this.label,
  });
}

class ModernBottomNav extends StatefulWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<ModernBottomNavItem> items;

  const ModernBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.items,
  });

  @override
  State<ModernBottomNav> createState() => _ModernBottomNavState();
}

class _ModernBottomNavState extends State<ModernBottomNav> {
  int? _previewIndex;
  int? _lastFeedbackIndex;

  void _commitIndex(int index) {
    if (index < 0 || index >= widget.items.length) return;

    final alreadyFelt = _lastFeedbackIndex == index;
    _clearPreview();

    if (index == widget.currentIndex) return;
    if (!alreadyFelt) HapticFeedback.selectionClick();
    widget.onTap(index);
  }

  void _previewPosition(Offset localPosition, double width) {
    final index = _indexFromLocalPosition(localPosition, width);
    if (index == null) return;

    if (_previewIndex != index) {
      setState(() => _previewIndex = index);
    }

    if (_lastFeedbackIndex != index && index != widget.currentIndex) {
      _lastFeedbackIndex = index;
      HapticFeedback.selectionClick();
    }
  }

  void _clearPreview() {
    if (_previewIndex == null && _lastFeedbackIndex == null) return;

    setState(() {
      _previewIndex = null;
      _lastFeedbackIndex = null;
    });
  }

  void _finishDrag() {
    final index = _previewIndex;
    _clearPreview();
    if (index != null) widget.onTap(index);
  }

  int? _indexFromLocalPosition(Offset localPosition, double width) {
    if (widget.items.isEmpty || width <= 0) return null;

    final itemWidth = width / widget.items.length;
    final index = (localPosition.dx / itemWidth).floor();
    if (index < 0 || index >= widget.items.length) return null;
    return index;
  }

  @override
  Widget build(BuildContext context) {
    const active = Color(0xFF7C63D8);
    const inactive = Color(0xFF7A7F8C);
    final cs = Theme.of(context).colorScheme;
    final selectedIndex = _previewIndex ?? widget.currentIndex;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(
            color: cs.outlineVariant.withValues(alpha: .42),
            width: .6,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .07),
            blurRadius: 18,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanDown: (details) =>
                _previewPosition(details.localPosition, constraints.maxWidth),
            onPanUpdate: (details) =>
                _previewPosition(details.localPosition, constraints.maxWidth),
            onPanEnd: (_) => _finishDrag(),
            onPanCancel: _clearPreview,
            onTapCancel: _clearPreview,
            child: NavigationBarTheme(
              data: NavigationBarThemeData(
                height: 64,
                backgroundColor: cs.surface,
                elevation: 0,
                indicatorColor: active.withValues(alpha: .13),
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                iconTheme: WidgetStateProperty.resolveWith((states) {
                  final selected = states.contains(WidgetState.selected);
                  return IconThemeData(
                    color: selected ? active : inactive,
                    size: 23,
                  );
                }),
                labelTextStyle: WidgetStateProperty.resolveWith((states) {
                  final selected = states.contains(WidgetState.selected);
                  return TextStyle(
                    color: selected ? active : inactive,
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                    height: 1,
                  );
                }),
              ),
              child: NavigationBar(
                selectedIndex: selectedIndex,
                onDestinationSelected: _commitIndex,
                destinations: [
                  for (final item in widget.items)
                    NavigationDestination(
                      icon: Icon(item.icon),
                      selectedIcon: Icon(item.icon),
                      label: item.label,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
