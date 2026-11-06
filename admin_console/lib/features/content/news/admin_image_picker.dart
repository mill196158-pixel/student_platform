import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'admin_photo_optimizer.dart';
import '../shared/content_media_intent.dart' show imageUploadMime;

/// Result of a local image selection for the admin prototype.
class PickedAdminImage {
  const PickedAdminImage({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    this.originalBytes,
    this.optimizationMessage,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
  /// Retained only until the sender accepts or rejects a lossy conversion.
  final Uint8List? originalBytes;
  final String? optimizationMessage;
}

class AdminImagePickException implements Exception {
  const AdminImagePickException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Small adapter between UI and the OS/browser file chooser.
///
/// Later this can call a secure upload flow while the editor stays unchanged.
abstract class AdminImagePicker {
  Future<PickedAdminImage?> pickImage();
}

class LocalAdminImagePicker implements AdminImagePicker {
  const LocalAdminImagePicker({this.photoMode, this.isCurrent, this.automatic = false});

  /// Null retains legacy behavior. True is explicit photo compression; false
  /// preserves the original bytes, including QR codes and documents.
  final bool? photoMode;
  final bool Function()? isCurrent;
  final bool automatic;
  static const allowedExtensions = ['jpg', 'jpeg', 'png', 'webp'];
  static const allowedMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};
  static const maxBytes = 5 * 1024 * 1024;
  static const maxInputBytes = 20 * 1024 * 1024;

  @override
  Future<PickedAdminImage?> pickImage() async {
    if (!(isCurrent?.call() ?? true)) return null;
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      withData: true,
      allowMultiple: false,
    );
    if (!(isCurrent?.call() ?? true) || result == null || result.files.isEmpty) return null;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      throw const AdminImagePickException(
        'Не удалось прочитать файл. Выберите изображение ещё раз.',
      );
    }

    final selected = await prepareSelected(
      bytes: bytes,
      fileName: file.name,
      mimeType: _guessMimeType(file.name, file.extension),
      photoMode: photoMode,
      isCurrent: isCurrent,
      automatic: automatic,
    );
    return (isCurrent?.call() ?? true) ? selected : null;
  }

  /// Processes an already selected file. Injectable optimizer supports
  /// deterministic tests without starting browser workers or file dialogs.
  static Future<PickedAdminImage> prepareSelected({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    Future<Uint8List?> Function(Uint8List)? optimizer,
    bool? photoMode,
    bool Function()? isCurrent,
    bool automatic = false,
  }) async {
    final original = _validateAndWrap(
      bytes: Uint8List.fromList(bytes),
      fileName: fileName,
      mimeType: mimeType,
      limit: maxInputBytes,
    );
    final String actualMime;
    try {
      actualMime = imageUploadMime(original.bytes);
    } catch (_) {
      throw const AdminImagePickException(
        'Выберите корректное изображение JPG, PNG или WebP.',
      );
    }
    final dot = original.fileName.lastIndexOf('.');
    final stem = dot > 0
        ? original.fileName.substring(0, dot)
        : original.fileName;
    final ext = switch (actualMime) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final safeOriginal = PickedAdminImage(
      bytes: original.bytes,
      fileName: '$stem.$ext',
      mimeType: actualMime,
    );
    if (photoMode == false) {
      if (original.bytes.length > maxBytes) {
        throw const AdminImagePickException(
          'Оригинал больше 5 МБ. Выберите файл меньшего размера.',
        );
      }
      return safeOriginal;
    }
    Uint8List? optimized;
    try {
      if (actualMime == 'image/png' &&
          (!automatic || original.bytes.length > 512 * 1024)) {
        final result = await (optimizer ?? optimizeAdminPhoto)(
          Uint8List.fromList(original.bytes),
        );
        optimized = result == null ? null : Uint8List.fromList(result);
      } else if (actualMime == 'image/jpeg' &&
          original.bytes.length > (photoMode == true ? 512 * 1024 : maxBytes)) {
        final eligible = photoMode != true || await isEligibleAdminPhotoJpeg(
            original.bytes, isCurrent: isCurrent);
        if (eligible && (isCurrent?.call() ?? true)) {
          // The encoder is lossy; source files are never modified.
          final result = await (optimizer ?? optimizeLargeJpegLegacy)(
            Uint8List.fromList(original.bytes),
          );
          optimized = result == null ? null : Uint8List.fromList(result);
        }
      }
    } catch (_) {
      optimized = null;
    }
    var good = false;
    try {
      good =
          optimized != null &&
          optimized.length < original.bytes.length &&
          optimized.length <= maxBytes &&
          (actualMime == 'image/png'
              ? await isLosslessAdminPhoto(original.bytes, optimized)
              : actualMime == 'image/jpeg' &&
                    await isValidLegacyJpeg(original.bytes, optimized));
    } catch (_) {
      good = false;
    }
    if (!good) {
      if (original.bytes.length > maxBytes) {
        throw const AdminImagePickException(
          'Не удалось уменьшить изображение до 5 МБ. Выберите другой файл.',
        );
      }
      if (automatic && original.bytes.length > 512 * 1024) {
        return PickedAdminImage(
          bytes: safeOriginal.bytes,
          fileName: safeOriginal.fileName,
          mimeType: safeOriginal.mimeType,
          optimizationMessage: 'Не удалось безопасно уменьшить изображение '
              '(${(original.bytes.length / 1024).ceil()} КБ). Выбран оригинал.',
        );
      }
      return safeOriginal;
    }
    return PickedAdminImage(
      bytes: optimized!,
      fileName: '$stem.${actualMime == 'image/jpeg' ? 'jpg' : 'png'}',
      mimeType: actualMime,
      originalBytes: automatic && actualMime == 'image/jpeg'
          ? Uint8List.fromList(original.bytes) : null,
      optimizationMessage: automatic && actualMime == 'image/png'
          ? 'PNG без потери качества: ${(original.bytes.length / 1024).ceil()} → ${(optimized!.length / 1024).ceil()} КБ.'
          : null,
    );
  }

  /// Shared validation for picker and drag-and-drop paths.
  static PickedAdminImage validateAndWrap({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) => _validateAndWrap(
    bytes: bytes,
    fileName: fileName,
    mimeType: mimeType,
    limit: maxBytes,
  );

  static PickedAdminImage _validateAndWrap({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required int limit,
  }) {
    final normalizedMime = mimeType.toLowerCase().trim();
    final extension = _extensionOf(fileName);

    final mimeOk = allowedMimeTypes.contains(normalizedMime);
    final extensionOk = allowedExtensions.contains(extension);
    if (!mimeOk && !extensionOk) {
      throw const AdminImagePickException(
        'Поддерживаются только JPG, PNG и WebP.',
      );
    }

    if (bytes.isEmpty) {
      throw const AdminImagePickException('Файл изображения пустой.');
    }

    if (bytes.length > limit) {
      throw AdminImagePickException(
        'Изображение слишком большое. Максимум ${limit ~/ (1024 * 1024)} МБ.',
      );
    }

    return PickedAdminImage(
      bytes: bytes,
      fileName: fileName,
      mimeType: mimeOk ? normalizedMime : _mimeFromExtension(extension),
    );
  }

  static String _guessMimeType(String fileName, String? extension) {
    final ext = (extension ?? _extensionOf(fileName)).toLowerCase();
    return _mimeFromExtension(ext);
  }

  static String _extensionOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  static String _mimeFromExtension(String extension) {
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'application/octet-stream',
    };
  }
}
