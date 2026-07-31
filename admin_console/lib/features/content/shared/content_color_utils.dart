import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Student-platform palette swatches (purple / teal / cream tones).
const List<Color> kContentAppColorSwatches = [
  Color(0xFFFFFBFF),
  Color(0xFFF3EEF9),
  Color(0xFFFAF8FC),
  Color(0xFFE8E0F5),
  Color(0xFFDCD0FA),
  Color(0xFFC9B8F3),
  Color(0xFF7C63D8),
  Color(0xFF6656D9),
  Color(0xFF6A4BBC),
  Color(0xFF4A3F8C),
  Color(0xFFE8F1FF),
  Color(0xFF2563EB),
  Color(0xFFE6F7F4),
  Color(0xFF2A9D8F),
  Color(0xFFFFF4E5),
  Color(0xFFD97706),
  Color(0xFFF5F5F5),
  Color(0xFF121212),
  Color(0xFF5C6370),
  Color(0xFFFFFFFF),
];

/// Parse `#RRGGBB` or `RRGGBB` into [Color]; null on failure.
Color? parseContentHexColor(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('#')) value = value.substring(1);
  if (value.length == 6) value = 'FF$value';
  if (value.length != 8) return null;
  final parsed = int.tryParse(value, radix: 16);
  if (parsed == null) return null;
  return Color(parsed);
}

/// Format [Color] as `#RRGGBB` (uppercase, no alpha).
String formatContentHexColor(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
}

/// WCAG relative luminance for sRGB color (0..1).
double contentRelativeLuminance(Color color) {
  double channel(double c) {
    c /= 255;
    return c <= 0.03928
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = channel((color.r * 255.0).roundToDouble());
  final g = channel((color.g * 255.0).roundToDouble());
  final b = channel((color.b * 255.0).roundToDouble());
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// Contrast ratio between two colors (1..21).
double contentContrastRatio(Color a, Color b) {
  final l1 = contentRelativeLuminance(a);
  final l2 = contentRelativeLuminance(b);
  final lighter = l1 > l2 ? l1 : l2;
  final darker = l1 > l2 ? l2 : l1;
  return (lighter + 0.05) / (darker + 0.05);
}

/// Returns a Russian warning when [foreground] on [background] is hard to read.
String? contentContrastWarning({
  required Color foreground,
  required Color background,
  double minRatio = 4.5,
}) {
  final ratio = contentContrastRatio(foreground, background);
  if (ratio >= minRatio) return null;
  return 'Низкий контраст (${ratio.toStringAsFixed(1)}:1). '
      'Текст может быть плохо читаем.';
}

/// Gradient direction in degrees (0 = →, 90 = ↓, 45 = ↘, 135 = ↙).
AlignmentGeometry contentGradientBegin(int degrees) {
  return switch (degrees) {
    0 => Alignment.centerLeft,
    90 => Alignment.topCenter,
    135 => Alignment.topRight,
    _ => Alignment.topLeft,
  };
}

AlignmentGeometry contentGradientEnd(int degrees) {
  return switch (degrees) {
    0 => Alignment.centerRight,
    90 => Alignment.bottomCenter,
    135 => Alignment.bottomLeft,
    _ => Alignment.bottomRight,
  };
}

/// Build a [LinearGradient] from two hex colors and direction degrees.
LinearGradient contentLinearGradientFromHex({
  required String colorA,
  required String colorB,
  int directionDegrees = 45,
}) {
  final a = parseContentHexColor(colorA) ?? const Color(0xFFFFFBFF);
  final b = parseContentHexColor(colorB) ?? const Color(0xFFF3EEF9);
  return LinearGradient(
    begin: contentGradientBegin(directionDegrees),
    end: contentGradientEnd(directionDegrees),
    colors: [a, b],
  );
}
