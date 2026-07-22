import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_image_store.dart';

/// Result of a completed upload to the private `news-media` bucket.
class UploadedNewsImage {
  const UploadedNewsImage({required this.path});

  /// Supabase Storage object path (never a public URL).
  final String path;
}

/// Media adapter for admin news images.
///
/// - Instant preview: [put] caches bytes in memory and returns a local id.
/// - Upload: [uploadPending] asks the `news-media` Edge Function for a signed
///   upload URL, PUTs the bytes, and returns the storage path.
/// - Download: [resolveBytes] asks for a signed download URL and fetches bytes.
///
/// No `service_role` key is used here and no base64 is ever written to the DB.
class SupabaseAdminImageStore implements AdminImageStore {
  SupabaseAdminImageStore({SupabaseClient? client, http.Client? httpClient})
    : _client = client ?? Supabase.instance.client,
      _http = httpClient ?? http.Client();

  final SupabaseClient _client;
  final http.Client _http;

  static const _bucket = 'news-media';
  static const _function = 'news-media';

  final Map<String, AdminStoredImage> _local = {};
  final Map<String, Uint8List> _remoteCache = {};
  int _nextId = 1;

  @override
  Uint8List? getBytes(String imageId) => _local[imageId]?.bytes;

  @override
  String? mimeTypeOf(String imageId) => _local[imageId]?.mimeType;

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
    _local[id] = stored;
    return stored;
  }

  @override
  Future<void> remove(String imageId) async {
    _local.remove(imageId);
  }

  /// Uploads locally-cached bytes for [localImageId] to the private bucket.
  ///
  /// When [previousPath] is provided, the old object is removed after a
  /// successful upload. Returns the new storage path.
  Future<String> uploadPending(
    String localImageId, {
    String? previousPath,
  }) async {
    final stored = _local[localImageId];
    if (stored == null) {
      throw StateError('Нет локального изображения для загрузки.');
    }

    final upload = await _invoke({
      'action': 'createUpload',
      'fileName': stored.fileName,
      'contentType': stored.mimeType,
      'fileSize': stored.bytes.length,
    });

    final path = (upload['path'] ?? '').toString();
    final token = (upload['token'] ?? '').toString();
    if (path.isEmpty || token.isEmpty) {
      throw StateError('Не удалось получить ссылку для загрузки.');
    }

    await _client.storage
        .from(_bucket)
        .uploadBinaryToSignedUrl(
          path,
          token,
          stored.bytes,
          FileOptions(contentType: stored.mimeType, upsert: true),
        );

    // Cache bytes under the resolved path for instant reads without a round-trip.
    _remoteCache[path] = stored.bytes;

    if (previousPath != null &&
        previousPath.isNotEmpty &&
        previousPath != path) {
      await deleteRemote(previousPath);
    }

    return path;
  }

  /// Resolves bytes for a stored object [imagePath] via a signed download URL.
  Future<Uint8List?> resolveBytes(String? imagePath) async {
    if (imagePath == null || imagePath.isEmpty) return null;
    final cached = _remoteCache[imagePath];
    if (cached != null) return cached;

    try {
      final download = await _invoke({
        'action': 'createDownload',
        'path': imagePath,
      });
      final signedUrl = (download['signedUrl'] ?? '').toString();
      if (signedUrl.isEmpty) return null;

      final response = await _http.get(Uri.parse(signedUrl));
      if (response.statusCode != 200) return null;
      final bytes = response.bodyBytes;
      _remoteCache[imagePath] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Removes a stored object. Best-effort; failures are swallowed.
  Future<void> deleteRemote(String imagePath) async {
    if (imagePath.isEmpty) return;
    try {
      await _invoke({'action': 'delete', 'path': imagePath});
      _remoteCache.remove(imagePath);
    } catch (_) {
      // Best-effort cleanup; a stale object is preferable to a failed save.
    }
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final response = await _client.functions.invoke(_function, body: body);
    final data = response.data;
    if (response.status >= 400) {
      throw StateError('Ошибка медиа-сервиса (${response.status}).');
    }
    if (data is Map) return Map<String, dynamic>.from(data);
    throw StateError('Некорректный ответ медиа-сервиса.');
  }
}
