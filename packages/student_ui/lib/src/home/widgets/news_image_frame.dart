import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Fixed-size news image surface with skeleton + soft crossfade.
///
/// Keeps layout stable while bytes load; never paints a folder glyph.
class NewsImageFrame extends StatelessWidget {
  const NewsImageFrame({
    required this.bytes,
    required this.colors,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.isLoading = false,
    this.hasError = false,
    this.fit = BoxFit.cover,
    super.key,
  });

  final Uint8List? bytes;
  final List<Color> colors;
  final Alignment alignment;
  final BorderRadius? borderRadius;
  final bool isLoading;
  final bool hasError;
  final BoxFit fit;

  bool get _hasBytes => bytes != null && bytes!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.zero;
    final base = colors.isNotEmpty ? colors.first : const Color(0xFFE9EAF1);
    final end = colors.length > 1 ? colors.last : const Color(0xFFD7D9E4);

    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Stable colored placeholder — exact size, no ticking animation.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(base, end, isLoading ? 0.35 : 0.20)!,
                  Color.lerp(end, base, isLoading ? 0.45 : 0.30)!,
                ],
              ),
            ),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _hasBytes
                ? Image.memory(
                    bytes!,
                    key: ValueKey<int>(bytes!.length),
                    fit: fit,
                    alignment: alignment,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  )
                : hasError
                    ? ColoredBox(
                        key: const ValueKey('error'),
                        color: Colors.black.withValues(alpha: 0.08),
                        child: const Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Color(0xFF8B8FA3),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('empty')),
          ),
        ],
      ),
    );
  }
}
