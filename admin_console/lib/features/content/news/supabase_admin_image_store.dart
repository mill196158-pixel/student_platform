import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:student_ui/student_ui.dart';
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
/// Remote bytes are cached by stable [NewsImageCacheKey] (path + version),
/// never by a temporary signed URL. Concurrent downloads are single-flight.
///
/// No `service_role` key is used here and no base64 is ever written to the DB.
class SupabaseAdminImageStore
    implements AdminImageStore, AdminRemoteImageGateway {
  SupabaseAdminImageStore({
    SupabaseClient? client,
    http.Client? httpClient,
    NewsImageBytesCache? cache,
  }) : _client = client ?? Supabase.instance.client,
       _http = httpClient ?? http.Client(),
       _cache = cache ?? NewsImageBytesCache.instance;

  final SupabaseClient _client;
  final http.Client _http;
  final NewsImageBytesCache _cache;

  static const _bucket = 'news-media';
  static const _function = 'news-media';

  final Map<String, AdminStoredImage> _local = {};
  int _nextId = 1;

  /// Clears private Admin image bytes (call on logout).
  @override
  void clearPrivateCache() {
    _cache.clear();
    _local.clear();
  }

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

  /// Seeds the shared cache after a successful upload so save/refresh keeps
  /// the same bytes without a download round-trip.
  @override
  void seedRemoteBytes({
    required String path,
    required String version,
    required Uint8List bytes,
  }) {
    _cache.put(NewsImageCacheKey(path: path, version: version), bytes);
  }

  /// Uploads locally-cached bytes for [localImageId] to the private bucket.
  ///
  /// Returns the new storage path. Caller deletes [previousPath] after a
  /// successful DB save.
  @override
  Future<String> uploadPending(
    String localImageId, {
    String? previousPath,
    String version = '0',
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

    seedRemoteBytes(path: path, version: version, bytes: stored.bytes);

    if (previousPath != null &&
        previousPath.isNotEmpty &&
        previousPath != path) {
      _cache.invalidatePath(previousPath);
    }

    return path;
  }

  /// Resolves bytes for a stored object via signed download (single-flight).
  ///
  /// [version] must be stable content identity (version_number / updated_at),
  /// never a signed URL.
  @override
  Future<Uint8List?> resolveBytes(
    String? imagePath, {
    required String version,
  }) async {
    if (imagePath == null || imagePath.isEmpty) return null;
    final key = NewsImageCacheKey(path: imagePath, version: version);
    return _cache.getOrFetch(key, () => _downloadOnce(imagePath));
  }

  @override
  Uint8List? peekBytes(String? imagePath, {required String version}) {
    if (imagePath == null || imagePath.isEmpty) return null;
    return _cache.peek(NewsImageCacheKey(path: imagePath, version: version));
  }

  @override
  void invalidatePath(String imagePath) => _cache.invalidatePath(imagePath);

  @override
  void invalidateKey(String imagePath, String version) {
    _cache.invalidateKey(NewsImageCacheKey(path: imagePath, version: version));
  }

  /// Removes a stored object. Best-effort; failures are swallowed.
  @override
  Future<void> deleteRemote(String imagePath) async {
    if (imagePath.isEmpty) return;
    try {
      await deleteRemoteStrict(imagePath);
    } catch (_) {
      // Best-effort cleanup; a stale object is preferable to a failed save.
    }
  }

  /// Removes a stored object and surfaces failures to the caller.
  @override
  Future<void> deleteRemoteStrict(String imagePath) async {
    if (imagePath.isEmpty) return;
    await _invoke({'action': 'delete', 'path': imagePath});
    _cache.invalidatePath(imagePath);
  }

  Future<Uint8List?> _downloadOnce(String imagePath) async {
    try {
      final download = await _invoke({
        'action': 'createDownload',
        'path': imagePath,
      });
      final signedUrl = (download['signedUrl'] ?? '').toString();
      if (signedUrl.isEmpty) return null;

      final response = await _http.get(Uri.parse(signedUrl));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
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
