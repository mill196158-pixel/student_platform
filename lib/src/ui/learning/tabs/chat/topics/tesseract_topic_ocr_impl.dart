import 'dart:io';

import 'package:flutter/services.dart';

import 'topic_list_models.dart';
import 'topic_list_parser.dart';

/// On-device Cyrillic OCR via platform channel (no third-party OCR Flutter pods).
///
/// * iOS 16+ — Apple Vision (`ru-RU` / `en-US`); iOS 15 installs app but OCR
///   returns a clear unsupported message (manual / Excel / Word still work).
/// * Android — Tesseract (`rus+eng`) with bundled tessdata assets (offline).
class TesseractTopicOcrAdapter extends TopicOcrAdapter {
  const TesseractTopicOcrAdapter({
    MethodChannel? channel,
    bool? supportsNativePlatform,
  })  : _channel = channel ?? const MethodChannel('student_platform/topic_ocr'),
        _supportsNativePlatform = supportsNativePlatform;

  final MethodChannel _channel;
  final bool? _supportsNativePlatform;

  bool get _isNativePlatform =>
      _supportsNativePlatform ?? (Platform.isAndroid || Platform.isIOS);

  /// Whether the native Cyrillic OCR path is usable on this device/OS.
  Future<bool> isAvailable() async {
    if (!_isNativePlatform) return false;
    try {
      final value = await _channel.invokeMethod<bool>('isAvailable');
      return value == true;
    } on MissingPluginException {
      // Channel not registered (e.g. hot-restart edge) — treat as unavailable.
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String> recognize(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw FormatException('Пустое изображение для OCR.');
    }
    if (bytes.length > topicListMaxFileBytes) {
      throw FormatException(
        'Изображение слишком большое (${bytes.length ~/ 1024} КБ). '
        'Максимум ${topicListMaxFileBytes ~/ (1024 * 1024)} МБ.',
      );
    }
    if (!_isNativePlatform) {
      return const UnavailableTopicOcrAdapter().recognize(bytes);
    }

    final available = await isAvailable();
    if (!available) {
      throw FormatException(
        Platform.isIOS
            ? 'Распознавание кириллицы с фото доступно на iOS 16 и новее. '
                'Введите темы вручную или выберите Excel/Word/PDF.'
            : 'Распознавание текста с изображения недоступно на этом устройстве. '
                'Введите темы вручную или выберите Excel/Word/PDF.',
      );
    }

    File? tempFile;
    try {
      // System temp avoids path_provider channel dependency (works in unit tests).
      tempFile = File(
        '${Directory.systemTemp.path}/topic_ocr_native_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(bytes, flush: true);

      final text = await _channel.invokeMethod<String>('recognize', {
        'path': tempFile.path,
        'languages': Platform.isIOS ? 'ru-RU,en-US' : 'rus+eng',
      });
      final trimmed = (text ?? '').trim();
      if (trimmed.isEmpty) {
        throw FormatException(
          'Не удалось распознать текст на изображении. Попробуйте другое фото.',
        );
      }
      return trimmed;
    } on FormatException {
      rethrow;
    } on MissingPluginException {
      throw FormatException(
        'Распознавание текста с изображения недоступно в этой сборке. '
        'Введите темы вручную или выберите Excel/Word/PDF.',
      );
    } on PlatformException catch (e) {
      throw FormatException(
        e.message?.trim().isNotEmpty == true
            ? e.message!.trim()
            : 'Не удалось распознать текст на изображении. Попробуйте другое фото.',
      );
    } catch (_) {
      throw FormatException(
        'Не удалось распознать текст на изображении. Попробуйте другое фото.',
      );
    } finally {
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {}
      }
    }
  }
}

TopicOcrAdapter createTesseractTopicOcrAdapter() {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return const UnavailableTopicOcrAdapter();
  }
  return const TesseractTopicOcrAdapter();
}
