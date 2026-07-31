import 'package:cached_network_image/cached_network_image.dart';
import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

/// Soft pastel team tile — matches app lavender UI instead of loud HSL solids.
class TeamAvatar extends StatelessWidget {
  const TeamAvatar({
    super.key,
    required this.name,
    this.icon = '',
    this.size = 44,
  });

  final String name;
  final String icon;
  final double size;

  static const _palettes = <(Color bg, Color fg)>[
    (Color(0xFFEDE7F6), Color(0xFF6B5BA8)), // lavender
    (Color(0xFFE3F2FD), Color(0xFF3D6FA8)), // soft blue
    (Color(0xFFE8F5E9), Color(0xFF3D8B5A)), // mint
    (Color(0xFFFFF3E0), Color(0xFFB86A2D)), // peach
    (Color(0xFFFCE4EC), Color(0xFFA14B6A)), // rose
    (Color(0xFFE0F7FA), Color(0xFF2F8A96)), // aqua
    (Color(0xFFF3E5F5), Color(0xFF7A4E9E)), // lilac
    (Color(0xFFEDE7E3), Color(0xFF7A6558)), // warm sand
  ];

  bool get _isUrl =>
      icon.startsWith('http://') || icon.startsWith('https://');

  static (Color bg, Color fg) colorsFor(String name) {
    final seed = name.trim().isEmpty ? 0 : name.hashCode.abs();
    return _palettes[seed % _palettes.length];
  }

  static String initialsFor(String value) {
    final words = value
        .trim()
        .split(RegExp(r'[\s\-.]+'))
        .where((word) => word.trim().isNotEmpty)
        .toList();
    if (words.isEmpty) return 'Т';

    final buffer = StringBuffer();
    for (final word in words.take(2)) {
      buffer.write(word.characters.first.toUpperCase());
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final initials = initialsFor(name);
    final (bg, fg) = colorsFor(name);
    final radius = size * 0.28;

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: const Color(0xFFE8E4F0)),
        boxShadow: [
          BoxShadow(
            color: fg.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
        image: _isUrl
            ? DecorationImage(
                image: CachedNetworkImageProvider(icon),
                fit: BoxFit.cover,
              )
            : null,
      ),
      alignment: Alignment.center,
      child: _isUrl
          ? null
          : Padding(
              padding: EdgeInsets.all(size * 0.14),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  initials,
                  maxLines: 1,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: fg,
                    fontSize: size * 0.38,
                    height: 1,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
    );
  }
}
