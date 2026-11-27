import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Full-bleed news image surface with a fixed-geometry fallback.
///
/// Always expands to the parent bounds. Image uses [BoxFit.cover] so the media
/// plane is edge-to-edge with no letterboxing and no stretched proportions.
class NewsImageFrame extends StatelessWidget {
  const NewsImageFrame({
    required this.bytes,
    required this.colors,
    this.imageProvider,
    this.alignment = Alignment.center,
    this.borderRadius,
    this.isLoading = false,
    this.hasError = false,
    this.fit = BoxFit.cover,
    super.key,
  });

  final Uint8List? bytes;
  final ImageProvider<Object>? imageProvider;
  final List<Color> colors;
  final Alignment alignment;
  final BorderRadius? borderRadius;
  final bool isLoading;
  final bool hasError;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.zero;
    final base = colors.isNotEmpty ? colors.first : const Color(0xFFE9EAF1);
    final end = colors.length > 1 ? colors.last : const Color(0xFFD7D9E4);
    final provider =
        imageProvider ?? (bytes?.isNotEmpty == true ? MemoryImage(bytes!) : null);

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
          if (hasError && provider == null)
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
          // A warmed provider provides its first frame synchronously.
          if (provider != null)
            Positioned.fill(
              child: Image(
                image: provider,
                fit: fit,
                alignment: alignment,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, __, ___) => const SizedBox.expand(),
              ),
            ),
        ],
      ),
    );
  }
}
