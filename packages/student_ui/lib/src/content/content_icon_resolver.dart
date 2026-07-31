import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'content_models.dart';

/// How an icon was resolved from payload fields.
sealed class ContentIconSource {
  const ContentIconSource();
}

/// Built-in Material icon from [iconKey].
final class ContentIconBuiltIn extends ContentIconSource {
  const ContentIconBuiltIn(this.key);

  final String key;
}

/// Custom uploaded icon asset (bytes resolved upstream).
final class ContentIconCustom extends ContentIconSource {
  const ContentIconCustom(this.assetId);

  final String assetId;
}

/// Explicitly no icon (both key and asset empty).
final class ContentIconNone extends ContentIconSource {
  const ContentIconNone();
}

/// Unknown icon key — fallback glyph shown.
final class ContentIconUnknown extends ContentIconSource {
  const ContentIconUnknown(this.raw);

  final String raw;
}

/// Result of [resolveContentIcon].
@immutable
class ContentIconResolved {
  const ContentIconResolved({
    this.iconData,
    this.isNone = false,
    this.isUnknown = false,
    this.customAssetId,
    this.source,
  });

  final IconData? iconData;
  final bool isNone;
  final bool isUnknown;
  final String? customAssetId;
  final ContentIconSource? source;
}

const _knownIconKeys = <String>{
  'psychology',
  'psychology_alt_outlined',
  'info',
  'school',
  'help',
  'work',
  'login',
  'download',
  'description',
  'computer',
  'map',
};

bool contentIconKeyIsKnown(String key) => _knownIconKeys.contains(key);

/// Resolve icon presentation from optional key / custom asset id.
///
/// Priority: custom asset id → built-in key → unknown fallback.
/// Returns [ContentIconNone] when both inputs are empty.
ContentIconResolved resolveContentIcon({
  String? iconKey,
  String? iconAssetId,
}) {
  final key = iconKey?.trim();
  final assetId = iconAssetId?.trim();
  final hasKey = key != null && key.isNotEmpty;
  final hasAsset = assetId != null && assetId.isNotEmpty;

  if (!hasKey && !hasAsset) {
    return const ContentIconResolved(
      isNone: true,
      source: ContentIconNone(),
    );
  }

  if (hasAsset) {
    // Custom asset: icon bytes may be supplied by caller; fall back to key or
    // unknown glyph when bytes are not yet available.
    IconData? fallback;
    ContentIconSource source = ContentIconCustom(assetId!);
    if (hasKey && contentIconKeyIsKnown(key!)) {
      fallback = contentIconForKey(key);
    } else if (hasKey) {
      fallback = Icons.widgets_outlined;
      source = ContentIconUnknown(key);
    } else {
      fallback = Icons.widgets_outlined;
    }
    return ContentIconResolved(
      iconData: fallback,
      customAssetId: assetId,
      isUnknown: hasKey && !contentIconKeyIsKnown(key),
      source: source,
    );
  }

  if (contentIconKeyIsKnown(key!)) {
    return ContentIconResolved(
      iconData: contentIconForKey(key),
      source: ContentIconBuiltIn(key),
    );
  }

  return ContentIconResolved(
    iconData: Icons.widgets_outlined,
    isUnknown: true,
    source: ContentIconUnknown(key),
  );
}

/// Paint resolved icon; custom [iconBytes] use [BoxFit.contain] (no SVG).
Widget contentIconWidget({
  required ContentIconResolved icon,
  Uint8List? iconBytes,
  required Color color,
  double size = 24,
}) {
  if (icon.isNone) return const SizedBox.shrink();
  final bytes = iconBytes;
  if (bytes != null &&
      bytes.isNotEmpty &&
      (icon.customAssetId != null || icon.source is ContentIconCustom)) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.memory(
        bytes,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => icon.iconData == null
            ? const SizedBox.shrink()
            : Icon(icon.iconData, color: color, size: size),
      ),
    );
  }
  if (icon.iconData == null) return const SizedBox.shrink();
  return Icon(icon.iconData, color: color, size: size);
}

/// Normalise card variant key; null/unknown → `gradient_text`.
String effectiveContentCardVariant(String? raw) {
  switch (raw) {
    case 'gradient_text':
    case 'image_full':
    case 'image_overlay':
    case 'image_top_text':
    case 'compact_icon':
    case 'accent_info':
    case 'no_image':
      return raw!;
    default:
      return 'gradient_text';
  }
}

/// Whether [variant] requires a hero image plane.
bool contentCardVariantUsesImage(String variant) {
  switch (variant) {
    case 'image_full':
    case 'image_overlay':
    case 'image_top_text':
      return true;
    default:
      return false;
  }
}

/// Gradient direction in degrees (0 = →, 90 = ↓, 45 = ↘, 135 = ↙).
Alignment contentGradientBegin(int? degrees) {
  return switch (degrees ?? 45) {
    0 => Alignment.centerLeft,
    90 => Alignment.topCenter,
    135 => Alignment.topRight,
    _ => Alignment.topLeft,
  };
}

Alignment contentGradientEnd(int? degrees) {
  return switch (degrees ?? 45) {
    0 => Alignment.centerRight,
    90 => Alignment.bottomCenter,
    135 => Alignment.bottomLeft,
    _ => Alignment.bottomRight,
  };
}

LinearGradient contentPayloadGradient({
  required List<Color> colors,
  int? angle,
  Alignment? begin,
  Alignment? end,
}) {
  final resolved = colors.length >= 2
      ? colors
      : const [Color(0xFFFFFBFF), Color(0xFFF3EEF9)];
  return LinearGradient(
    begin: begin ?? contentGradientBegin(angle),
    end: end ?? contentGradientEnd(angle),
    colors: resolved,
  );
}

/// Overlay dim for image-overlay cards; [raw] null → [defaultOpacity] (0.45).
double contentPayloadOverlayOpacity(
  double? raw, {
  double defaultOpacity = 0.45,
}) {
  if (raw == null) return defaultOpacity;
  return raw.clamp(0.0, 1.0);
}

/// Maps payload focal_x/focal_y (0..1) to [Alignment] for [Image.memory].
Alignment contentPayloadFocalAlignment({
  double? focalX,
  double? focalY,
}) {
  final x = (focalX ?? 0.5).clamp(0.0, 1.0);
  final y = (focalY ?? 0.5).clamp(0.0, 1.0);
  return Alignment(x * 2 - 1, y * 2 - 1);
}

/// Hero image fit from payload; unknown/null → cover.
BoxFit contentPayloadImageFit(String? raw) {
  switch (raw) {
    case 'contain':
      return BoxFit.contain;
    case 'cover':
    default:
      return BoxFit.cover;
  }
}

/// Fixed outer height for home promo image_full / image_overlay (unbounded scroll).
const double kHomePromoImageBleedHeight = 180;
