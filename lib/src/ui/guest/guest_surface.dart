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
          gradient: colors == null ? null : LinearGradient(colors: colors!),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: guestPurple.withValues(alpha: .06)),
        ),
        child: child,
      );
}

class GuestSectionHeader extends StatelessWidget {
  const GuestSectionHeader(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.icon,
      required this.onInfo});
  final String title, subtitle;
  final IconData icon;
  final VoidCallback onInfo;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 28, 16, 24),
        decoration: const BoxDecoration(
            gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFAF8FC), Color(0xFFE8E1F5), Color(0xFFF4F0FA)],
        )),
        child: Row(children: [
          Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: guestPurple.withValues(alpha: .10),
                  boxShadow: const [
                    BoxShadow(color: Colors.white, blurRadius: 12)
                  ]),
              child: Icon(icon, color: guestPurple, size: 28)),
          const SizedBox(width: 14),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        height: 1.1)),
                const SizedBox(height: 5),
                Text(subtitle,
                    style:
                        const TextStyle(fontSize: 13, color: Color(0xFF676575)))
              ])),
          IconButton.filledTonal(
              tooltip: 'О разделе',
              onPressed: onInfo,
              style: IconButton.styleFrom(backgroundColor: Colors.white),
              icon: const Icon(Icons.info_outline_rounded, color: guestPurple)),
        ]),
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
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(18),
              child: Ink(
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .82),
                      gradient: colors == null
                          ? null
                          : LinearGradient(colors: colors!),
                      borderRadius: BorderRadius.circular(18)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Row(children: [
                    Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                            color: guestPurple.withValues(alpha: .08),
                            borderRadius: BorderRadius.circular(13)),
                        child: Icon(icon, size: 22, color: guestPurple)),
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
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF676575)),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis)
                          ]
                        ])),
                    trailing ??
                        const Icon(Icons.chevron_right,
                            color: Color(0xFF747581)),
                  ])),
            )),
      );
}
