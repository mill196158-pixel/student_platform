import 'dart:typed_data';

/// Local/remote image storage for admin content.
///
/// Stage 12.0 uses an in-memory implementation. A later Supabase Storage
/// adapter can replace it without changing the news editor UI.
abstract class AdminImageStore {
  Uint8List? getBytes(String imageId);

  String? mimeTypeOf(String imageId);

  Future<AdminStoredImage> put({
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
  });

  Future<void> remove(String imageId);
}

class AdminStoredImage {
  const AdminStoredImage({
    required this.id,
    required this.bytes,
    required this.mimeType,
    required this.fileName,
  });

  final String id;
  final Uint8List bytes;
  final String mimeType;
  final String fileName;
}

class LocalAdminImageStore implements AdminImageStore {
  final Map<String, AdminStoredImage> _images = {};
  int _nextId = 1;

  @override
  Uint8List? getBytes(String imageId) => _images[imageId]?.bytes;

  @override
  String? mimeTypeOf(String imageId) => _images[imageId]?.mimeType;

  @override
  Future<AdminStoredImage> put({
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
  }) async {
    final id = 'local-image-${_nextId++}';
    final stored = AdminStoredImage(
      id: id,
      bytes: bytes,
      mimeType: mimeType,
      fileName: fileName,
    );
    _images[id] = stored;
    return stored;
  }

  @override
  Future<void> remove(String imageId) async {
    _images.remove(imageId);
  }
}
