import 'package:flutter/material.dart';

class PublicationStatusBadge extends StatelessWidget {
  const PublicationStatusBadge({required this.status, super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final style = _styleFor(status);
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: style.background,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: style.border, width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(style.icon, size: 14, color: style.foreground),
                const SizedBox(width: 6),
                Text(
                  status,
                  style: TextStyle(
                    color: style.foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static _BadgeStyle _styleFor(String status) {
    switch (status) {
      case 'Опубликован':
        return const _BadgeStyle(
          background: Color(0x1F2F8B5E),
          border: Color(0xFF2F8B5E),
          foreground: Color(0xFF1F5E3D),
          icon: Icons.check_circle_rounded,
        );
      case 'В архиве':
        return const _BadgeStyle(
          background: Color(0x1F5C6370),
          border: Color(0xFF6E7583),
          foreground: Color(0xFF3F4654),
          icon: Icons.inventory_2_outlined,
        );
      case 'Черновик':
      default:
        return const _BadgeStyle(
          background: Color(0x29C9851F),
          border: Color(0xFFC9851F),
          foreground: Color(0xFF8A5A0F),
          icon: Icons.edit_note_rounded,
        );
    }
  }
}

class _BadgeStyle {
  const _BadgeStyle({
    required this.background,
    required this.border,
    required this.foreground,
    required this.icon,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final IconData icon;
}
