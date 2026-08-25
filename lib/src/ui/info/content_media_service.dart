import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ContentMediaDownload {
  const ContentMediaDownload({
    required this.signedUrl,
    required this.expiresAt,
    this.mimeType,
  });

  final String signedUrl;
  final DateTime expiresAt;
  final String? mimeType;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get shouldRefresh {
    if (isExpired) return true;
    return expiresAt.difference(DateTime.now()) < const Duration(minutes: 1);
  }
}

/// Mobile signed-download helper for Stage 16.3 `content-media` assets.
///
/// Cache key contract (Stage 14.1.4): `userScope + assetId + contentVersion`.
/// Signed URLs are never used as cache keys. Bytes are single-flight per key.
class ContentMediaService {
  ContentMediaService({
    SupabaseClient? client,
    http.Client? httpClient,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _client = client,
        _http = httpClient ?? http.Client(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId;

  final SupabaseClient? _client;
  SupabaseClient get _sb => _client ?? Supabase.instance.client;
  final http.Client _http;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function()? _currentUserId;

  static const _function = 'content-media';
  static const _urlCachePrefix = 'content_media_url_v2';
  static const _legacyUrlCachePrefix = 'content_media_url_v1';

  final Map<String, ContentMediaDownload> _memoryUrls = {};
  final Map<String, Uint8List> _bytesMemory = {};
  final Map<String, Future<Uint8List?>> _inflightBytes = {};

  String? _uid() {
    final direct = _currentUserId?.call();
    if (direct != null) return direct;
    if (_client != null) return _client.auth.currentUser?.id;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  String get _userScope {
    final user = (_uid() ?? '').trim();
    return user.isEmpty ? 'anon' : user;
  }

  /// Stable media identity: never path / signed URL.
  String cacheKey(String assetId, {String? contentVersion}) {
    final id = assetId.trim();
    final version = (contentVersion ?? '').trim();
    if (version.isEmpty) return '$_userScope|$id';
    return '$_userScope|$id|$version';
  }

  Future<ContentMediaDownload?> resolveDownload(
    String assetId, {
    String? contentVersion,
  }) async {
    final id = assetId.trim();
    if (id.isEmpty) return null;

    final memKey = cacheKey(id, contentVersion: contentVersion);
    final cached = _memoryUrls[memKey];
    if (cached != null && !cached.shouldRefresh) return cached;

    final persisted = await _readPersistedUrl(memKey);
    if (persisted != null && !persisted.shouldRefresh) {
      _memoryUrls[memKey] = persisted;
      return persisted;
    }

    try {
      final response = await _sb.functions.invoke(
        _function,
        body: {
          'action': 'createDownload',
          'assetId': id,
        },
      );
      if (response.status == 403 || response.status == 401) {
        await clearAsset(id, contentVersion: contentVersion);
        return null;
      }
      if (response.status >= 400) return null;
      final data = response.data;
      if (data is! Map) return null;
      if (_leaksStoragePath(data)) {
        debugPrint('[content_media] createDownload leaked path — rejected');
        return null;
      }
      final signedUrl = (data['signedUrl'] ?? '').toString();
      if (signedUrl.isEmpty) return null;
      final expiresIn = int.tryParse('${data['expiresIn'] ?? 3600}') ?? 3600;
      final download = ContentMediaDownload(
        signedUrl: signedUrl,
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
        mimeType: data['mimeType']?.toString(),
      );
      _memoryUrls[memKey] = download;
      await _writePersistedUrl(memKey, download);
      return download;
    } catch (e) {
      debugPrint('[content_media] createDownload failed type=${e.runtimeType}');
      return null;
    }
  }

  /// Single-flight byte fetch keyed by [cacheKey].
  Future<Uint8List?> fetchBytes(
    String assetId, {
    String? contentVersion,
  }) {
    final id = assetId.trim();
    if (id.isEmpty) return Future<Uint8List?>.value(null);

    final key = cacheKey(id, contentVersion: contentVersion);
    final cached = _bytesMemory[key];
    if (cached != null && cached.isNotEmpty) {
      return Future<Uint8List?>.value(cached);
    }

    return _inflightBytes.putIfAbsent(key, () async {
      try {
        final download = await resolveDownload(
          id,
          contentVersion: contentVersion,
        );
        if (download == null) return null;
        final response = await _http.get(Uri.parse(download.signedUrl));
        if (response.statusCode == 403 || response.statusCode == 401) {
          await clearAsset(id, contentVersion: contentVersion);
          return null;
        }
        if (response.statusCode != 200) return null;
        final bytes = response.bodyBytes;
        if (bytes.isEmpty) return null;
        _bytesMemory[key] = bytes;
        return bytes;
      } catch (e) {
        debugPrint('[content_media] download failed type=${e.runtimeType}');
        return null;
      } finally {
        _inflightBytes.remove(key);
      }
    });
  }

  Future<void> clearAll() async {
    _memoryUrls.clear();
    _bytesMemory.clear();
    _inflightBytes.clear();
    try {
      final prefs = await _prefs();
      final scope = _userScope;
      for (final key in prefs.getKeys()) {
        final isV2 =
            key.startsWith('${_urlCachePrefix}__') && key.contains('$scope|');
        final isLegacy = key.startsWith('${_legacyUrlCachePrefix}__') &&
            key.contains('$scope|');
        if (isV2 || isLegacy) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  Future<void> clearAsset(
    String assetId, {
    String? contentVersion,
  }) async {
    final memKey = cacheKey(assetId.trim(), contentVersion: contentVersion);
    _memoryUrls.remove(memKey);
    _bytesMemory.remove(memKey);
    _inflightBytes.remove(memKey);
    try {
      final prefs = await _prefs();
      await prefs.remove('${_urlCachePrefix}__$memKey');
      // Legacy key without version.
      await prefs.remove(
        '${_legacyUrlCachePrefix}__${_userScope}|${assetId.trim()}',
      );
    } catch (_) {}
  }

  bool _leaksStoragePath(Map data) {
    for (final key in ['storagePath', 'storage_path', 'path', 'objectPath']) {
      final value = data[key];
      if (value != null && value.toString().trim().isNotEmpty) return true;
    }
    return false;
  }

  Future<ContentMediaDownload?> _readPersistedUrl(String memKey) async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString('${_urlCachePrefix}__$memKey') ??
          prefs.getString('${_legacyUrlCachePrefix}__$memKey');
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final url = (map['signedUrl'] ?? '').toString();
      final expiresRaw = (map['expiresAt'] ?? '').toString();
      final expiresAt = DateTime.tryParse(expiresRaw);
      if (url.isEmpty || expiresAt == null) return null;
      return ContentMediaDownload(
        signedUrl: url,
        expiresAt: expiresAt,
        mimeType: map['mimeType']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePersistedUrl(
    String memKey,
    ContentMediaDownload download,
  ) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
        '${_urlCachePrefix}__$memKey',
        jsonEncode({
          'signedUrl': download.signedUrl,
          'expiresAt': download.expiresAt.toIso8601String(),
          'mimeType': download.mimeType,
        }),
      );
    } catch (_) {}
  }
}
