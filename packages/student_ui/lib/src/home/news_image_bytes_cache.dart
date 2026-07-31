import 'dart:collection';
import 'dart:typed_data';

/// Stable cache identity for a private news image.
///
/// Keyed by storage [path] + content [version] (version_number / updated_at).
/// Never use a signed URL as the identity.
class NewsImageCacheKey {
  const NewsImageCacheKey({required this.path, required this.version});

  final String path;
  final String version;

  String get id => '$path|$version';

  static NewsImageCacheKey? tryParse({
    required String? path,
    Object? versionNumber,
    DateTime? updatedAt,
  }) {
    final trimmed = path?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    final version = [
      if (versionNumber != null) versionNumber.toString(),
      if (updatedAt != null)
        updatedAt.toUtc().millisecondsSinceEpoch.toString(),
    ].join(':');
    return NewsImageCacheKey(
      path: trimmed,
      version: version.isEmpty ? '0' : version,
    );
  }
}

/// In-memory LRU + single-flight cache for decoded news image bytes.
///
/// Limits:
/// - [maxEntries] objects
/// - [maxTotalBytes] approximate total payload size
///
/// Suitable for Admin Web (session memory) and as the hot layer for Mobile
/// (backed by a disk store on the app side).
class NewsImageBytesCache {
  NewsImageBytesCache({
    this.maxEntries = 64,
    this.maxTotalBytes = 32 * 1024 * 1024,
  });

  /// Shared process-wide instance used by Admin + Mobile presentation.
  static final NewsImageBytesCache instance = NewsImageBytesCache();

  final int maxEntries;
  final int maxTotalBytes;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List?>> _inflight = {};

  int _totalBytes = 0;

  /// Test/telemetry: completed network fetches (not cache hits).
  int downloadCount = 0;

  /// Test/telemetry: number of currently in-flight fetches.
  int get inflightCount => _inflight.length;

  int get entryCount => _memory.length;

  int get totalBytes => _totalBytes;

  Uint8List? peek(NewsImageCacheKey key) {
    final bytes = _memory.remove(key.id);
    if (bytes == null) return null;
    // Refresh LRU order.
    _memory[key.id] = bytes;
    return bytes;
  }

  void put(NewsImageCacheKey key, Uint8List bytes) {
    if (bytes.isEmpty) return;
    final existing = _memory.remove(key.id);
    if (existing != null) {
      _totalBytes -= existing.length;
    }
    _memory[key.id] = bytes;
    _totalBytes += bytes.length;
    _evictIfNeeded();
  }

  /// Returns cached bytes or runs [fetch] once (single-flight per key).
  Future<Uint8List?> getOrFetch(
    NewsImageCacheKey key,
    Future<Uint8List?> Function() fetch,
  ) {
    final cached = peek(key);
    if (cached != null) return Future<Uint8List?>.value(cached);

    final existing = _inflight[key.id];
    if (existing != null) return existing;

    final future = () async {
      try {
        final bytes = await fetch();
        if (bytes != null && bytes.isNotEmpty) {
          downloadCount += 1;
          put(key, bytes);
        }
        return bytes;
      } finally {
        _inflight.remove(key.id);
      }
    }();
    _inflight[key.id] = future;
    return future;
  }

  void invalidateKey(NewsImageCacheKey key) {
    final removed = _memory.remove(key.id);
    if (removed != null) _totalBytes -= removed.length;
    _inflight.remove(key.id);
  }

  /// Drops every cached version for [path].
  void invalidatePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return;
    final prefix = '$trimmed|';
    final toRemove = _memory.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in toRemove) {
      final removed = _memory.remove(key);
      if (removed != null) _totalBytes -= removed.length;
    }
    _inflight.removeWhere((key, _) => key.startsWith(prefix));
  }

  void clear() {
    _memory.clear();
    _inflight.clear();
    _totalBytes = 0;
  }

  void _evictIfNeeded() {
    while ((_memory.length > maxEntries || _totalBytes > maxTotalBytes) &&
        _memory.isNotEmpty) {
      final firstKey = _memory.keys.first;
      final removed = _memory.remove(firstKey);
      if (removed != null) _totalBytes -= removed.length;
    }
  }
}
