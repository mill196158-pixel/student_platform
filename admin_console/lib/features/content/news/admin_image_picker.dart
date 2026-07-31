import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

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

    return validateAndWrap(
      bytes: bytes,
      fileName: file.name,
      mimeType: _guessMimeType(file.name, file.extension),
    );
  }

  /// Shared validation for picker and drag-and-drop paths.
  static PickedAdminImage validateAndWrap({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
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

    if (bytes.length > maxBytes) {
      throw const AdminImagePickException(
        'Изображение слишком большое. Максимум 5 МБ.',
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
