import 'dart:typed_data';

import 'topic_list_parser.dart';

/// ML Kit first; Cyrillic on-device fallback only when primary is weak/empty.
class CompositeTopicOcrAdapter extends TopicOcrAdapter {
  CompositeTopicOcrAdapter({
    required TopicOcrAdapter primary,
    required TopicOcrAdapter cyrillicFallback,
  })  : _primary = primary,
        _fallback = cyrillicFallback;

  final TopicOcrAdapter _primary;
  final TopicOcrAdapter _fallback;

  @override
  Future<String> recognize(Uint8List bytes) async {
    String? primaryText;
    try {
      primaryText = (await _primary.recognize(bytes)).trim();
      if (_hasStrongCyrillic(primaryText)) {
        return primaryText;
      }
    } catch (_) {
      primaryText = null;
    }

    try {
      final fallbackText = (await _fallback.recognize(bytes)).trim();
      if (fallbackText.isEmpty) {
        if (primaryText != null && primaryText.isNotEmpty) return primaryText;
        throw FormatException(
          'Не удалось распознать текст на изображении. Попробуйте другое фото.',
        );
      }
      if (primaryText == null || primaryText.isEmpty) return fallbackText;
      return _preferBetterOcr(primaryText, fallbackText);
    } catch (e) {
      if (primaryText != null && primaryText.isNotEmpty) return primaryText;
      if (e is FormatException) rethrow;
      throw FormatException(
        'Не удалось распознать текст на изображении. Попробуйте другое фото.',
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _primary.dispose();
    await _fallback.dispose();
  }

  static String _preferBetterOcr(String primary, String fallback) {
    final primaryCyr = _cyrillicCount(primary);
    final fallbackCyr = _cyrillicCount(fallback);
    if (fallbackCyr > primaryCyr) return fallback;
    if (fallbackCyr == primaryCyr &&
        _ocrQualityScore(fallback) >= _ocrQualityScore(primary)) {
      return fallback;
    }
    return primary;
  }

  static bool _hasStrongCyrillic(String text) {
    final letters = _letterCount(text);
    final cyrillic = _cyrillicCount(text);
    if (letters < 12) return false;
    return cyrillic * 2 >= letters;
  }

  static int _ocrQualityScore(String text) {
    if (text.trim().isEmpty) return 0;
    final letters = _letterCount(text);
    final cyrillic = _cyrillicCount(text);
    final lines =
        text.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).length;
    final numbered = RegExp(r'(?m)^\s*\d+[\.\)]\s+\S').allMatches(text).length;
    final cyrBonus = letters == 0 ? 0 : ((cyrillic * 12) ~/ letters);
    return cyrBonus + (lines > 8 ? 8 : lines) + (numbered * 2);
  }

  static int _cyrillicCount(String text) {
    var cyrillic = 0;
    for (final unit in text.runes) {
      if (unit >= 0x0400 && unit <= 0x04FF) cyrillic++;
    }
    return cyrillic;
  }

  static int _letterCount(String text) {
    var letters = 0;
    for (final unit in text.runes) {
      final isCyr = unit >= 0x0400 && unit <= 0x04FF;
      final isLat =
          (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
      if (isCyr || isLat) letters++;
    }
    return letters;
  }
}
