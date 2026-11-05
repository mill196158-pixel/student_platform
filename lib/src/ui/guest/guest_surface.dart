import 'package:flutter/material.dart';

// Same palette, radii and header composition as the existing student screens.
const guestPurple = Color(0xFF7C63D8);
const guestInk = Color(0xFF1F2937);
const guestBlend = [Color(0xFFDCD0FA), Color(0xFFC5EFE5)];

class GuestPanel extends StatelessWidget {
  const GuestPanel(
      {super.key,
      required this.child,
      this.colors,
      this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final List<Color>? colors;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: child,
      );
}

class GuestActionTile extends StatelessWidget {
  const GuestActionTile(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.icon,
      required this.onTap,
      this.trailing,
      this.colors});
  final String title, subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final Widget? trailing;
  final List<Color>? colors;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Ink(
                decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(12)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(children: [
                  Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(13)),
                      child: Icon(icon,
                          size: 22, color: scheme.onPrimaryContainer)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(title,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(subtitle,
                              style: TextStyle(
                                  fontSize: 12, color: scheme.onSurfaceVariant),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis)
                        ]
                      ])),
                  trailing ??
                      Icon(Icons.chevron_right_rounded,
                          color: scheme.onSurfaceVariant),
                ])),
          )),
    );
  }
}
