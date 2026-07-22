import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Full-bleed news image surface with skeleton + soft crossfade.
///
/// Always expands to the parent bounds. Image uses [BoxFit.cover] so the media
/// plane is edge-to-edge with no letterboxing and no stretched proportions.
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
          // Exact-size skeleton / error underlay (same geometry as the image).
          Positioned.fill(
            child: DecoratedBox(
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
          ),
          if (hasError && !_hasBytes)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x14000000),
                child: Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Color(0xFF8B8FA3),
                  ),
                ),
              ),
            ),
          // Full-bleed photo — must fill the stack or the underlay shows as stripes.
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              child: _hasBytes
                  ? SizedBox.expand(
                      key: ValueKey<int>(bytes!.length),
                      child: Image.memory(
                        bytes!,
                        fit: fit,
                        alignment: alignment,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, __, ___) => const SizedBox.expand(),
                      ),
                    )
                  : const SizedBox.expand(key: ValueKey('empty')),
            ),
          ),
        ],
      ),
    );
  }
}
