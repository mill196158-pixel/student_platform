import 'dart:convert';

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
  static const _urlCachePrefix = 'content_media_url_v1';

  final Map<String, ContentMediaDownload> _memoryUrls = {};

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

  String _urlKey(String assetId) => '$_userScope|$assetId';

  Future<ContentMediaDownload?> resolveDownload(String assetId) async {
    final id = assetId.trim();
    if (id.isEmpty) return null;

    final memKey = _urlKey(id);
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
        await clearAsset(id);
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

  Future<Uint8List?> fetchBytes(String assetId) async {
    final download = await resolveDownload(assetId);
    if (download == null) return null;
    try {
      final response = await _http.get(Uri.parse(download.signedUrl));
      if (response.statusCode == 403 || response.statusCode == 401) {
        await clearAsset(assetId);
        return null;
      }
      if (response.statusCode != 200) return null;
      final bytes = response.bodyBytes;
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      debugPrint('[content_media] download failed type=${e.runtimeType}');
      return null;
    }
  }

  Future<void> clearAll() async {
    _memoryUrls.clear();
    try {
      final prefs = await _prefs();
      final scope = _userScope;
      for (final key in prefs.getKeys()) {
        if (key.startsWith('${_urlCachePrefix}__') && key.contains('$scope|')) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  Future<void> clearAsset(String assetId) async {
    final memKey = _urlKey(assetId.trim());
    _memoryUrls.remove(memKey);
    try {
      final prefs = await _prefs();
      await prefs.remove('${_urlCachePrefix}__$memKey');
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
      final raw = prefs.getString('${_urlCachePrefix}__$memKey');
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
