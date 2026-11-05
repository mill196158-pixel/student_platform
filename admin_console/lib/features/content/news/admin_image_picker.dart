import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'admin_photo_optimizer.dart';

/// Result of a local image selection for the admin prototype.
class PickedAdminImage {
  const PickedAdminImage({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String fileName;
  final String mimeType;
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
  static const allowedExtensions = ['jpg', 'jpeg', 'png', 'webp'];
  static const allowedMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};
  static const maxBytes = 5 * 1024 * 1024;
  static const maxInputBytes = 20 * 1024 * 1024;

  @override
  Future<PickedAdminImage?> pickImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      withData: true,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      throw const AdminImagePickException(
        'Не удалось прочитать файл. Выберите изображение ещё раз.',
      );
    }

    return prepareSelected(
      bytes: bytes,
      fileName: file.name,
      mimeType: _guessMimeType(file.name, file.extension),
    );
  }

  /// Processes an already selected file. Injectable optimizer supports
  /// deterministic tests without starting browser workers or file dialogs.
  static Future<PickedAdminImage> prepareSelected({required Uint8List bytes,
      required String fileName, required String mimeType,
      Future<Uint8List?> Function(Uint8List)? optimizer}) async {
    final original = _validateAndWrap(bytes: bytes, fileName: fileName,
      mimeType: mimeType, limit: maxInputBytes);
    Uint8List? optimized;
    try {
      optimized = await (optimizer ?? optimizeAdminPhoto)(original.bytes);
    } catch (_) {
      optimized = null;
    }
    if (optimized == null || optimized.length < 3 || optimized.length >= original.bytes.length ||
        optimized.length > maxBytes || optimized[0] != 0xff || optimized[1] != 0xd8 || optimized[2] != 0xff) {
      if (original.bytes.length > maxBytes) {
        throw const AdminImagePickException(
          'Не удалось уменьшить изображение до 5 МБ. Выберите другой файл.',
        );
      }
      return original;
    }
    final dot = original.fileName.lastIndexOf('.');
    final stem = dot > 0 ? original.fileName.substring(0, dot) : original.fileName;
    return PickedAdminImage(bytes: optimized, fileName: '$stem.jpg', mimeType: 'image/jpeg');
  }

  /// Shared validation for picker and drag-and-drop paths.
  static PickedAdminImage validateAndWrap({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) => _validateAndWrap(bytes: bytes, fileName: fileName, mimeType: mimeType, limit: maxBytes);

  static PickedAdminImage _validateAndWrap({required Uint8List bytes,
    required String fileName, required String mimeType, required int limit}) {
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
