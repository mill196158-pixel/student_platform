import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class VacancyMediaDownload {
  const VacancyMediaDownload({
    required this.signedUrl,
    required this.expiresAt,
    this.mimeType,
    this.title,
  });

  final String signedUrl;
  final DateTime expiresAt;
  final String? mimeType;
  final String? title;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get shouldRefresh {
    if (isExpired) return true;
    return expiresAt.difference(DateTime.now()) < const Duration(minutes: 1);
  }
}

/// Mobile signed-download helper for Stage 17 vacancy assets (`vacancy-media`).
///
/// Cache key: `userScope + assetId + contentVersion` (Stage 14.1.4).
class VacancyMediaService {
  VacancyMediaService({
    SupabaseClient? client,
    http.Client? httpClient,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _client = client,
        _http = httpClient ?? http.Client(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId;

  final SupabaseClient? _client;
  final http.Client _http;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function()? _currentUserId;

  static const _function = 'vacancy-media';
  static const _urlCachePrefix = 'vacancy_media_url_v2';
  static const _legacyUrlCachePrefix = 'vacancy_media_url_v1';

  final Map<String, VacancyMediaDownload> _memoryUrls = {};
  final Map<String, Uint8List> _bytesMemory = {};
  final Map<String, Future<Uint8List?>> _inflightBytes = {};

  SupabaseClient get _sb => _client ?? Supabase.instance.client;

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

  String cacheKey(String assetId, {String? contentVersion}) {
    final id = assetId.trim();
    final version = (contentVersion ?? '').trim();
    if (version.isEmpty) return '$_userScope|$id';
    return '$_userScope|$id|$version';
  }

  Future<VacancyMediaDownload?> resolveDownload(
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
        body: {'action': 'createDownload', 'assetId': id},
      );
      if (response.status >= 400) {
        debugPrint('[vacancy-media] download denied: ${response.status}');
        return null;
      }
      final data = Map<String, dynamic>.from(response.data as Map);
      final signedUrl = (data['signedUrl'] ?? '').toString();
      if (signedUrl.isEmpty) return null;
      final expiresIn = (data['expiresIn'] as num?)?.toInt() ?? 3600;
      final download = VacancyMediaDownload(
        signedUrl: signedUrl,
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
        mimeType: data['mimeType']?.toString(),
        title: data['title']?.toString(),
      );
      _memoryUrls[memKey] = download;
      await _persistUrl(memKey, download);
      return download;
    } catch (e) {
      debugPrint('[vacancy-media] resolve failed: $e');
      return null;
    }
  }

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
        if (response.statusCode != 200) return null;
        final bytes = response.bodyBytes;
        if (bytes.isEmpty) return null;
        _bytesMemory[key] = bytes;
        return bytes;
      } catch (e) {
        debugPrint('[vacancy-media] download failed: $e');
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
            key.startsWith('$_urlCachePrefix|') && key.contains('$scope|');
        final isLegacy = key.startsWith('$_legacyUrlCachePrefix|') &&
            key.contains('$scope|');
        if (isV2 || isLegacy) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  Future<String?> openAsset(String assetId, {String? contentVersion}) async {
    final download = await resolveDownload(
      assetId,
      contentVersion: contentVersion,
    );
    if (download == null) return null;
    return download.signedUrl;
  }

  Future<VacancyMediaDownload?> _readPersistedUrl(String key) async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString('$_urlCachePrefix|$key') ??
          prefs.getString('$_legacyUrlCachePrefix|$key');
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final signedUrl = map['signedUrl']?.toString();
      final expiresAt = DateTime.tryParse(map['expiresAt']?.toString() ?? '');
      if (signedUrl == null || expiresAt == null) return null;
      return VacancyMediaDownload(
        signedUrl: signedUrl,
        expiresAt: expiresAt,
        mimeType: map['mimeType']?.toString(),
        title: map['title']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistUrl(String key, VacancyMediaDownload download) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
        '$_urlCachePrefix|$key',
        jsonEncode({
          'signedUrl': download.signedUrl,
          'expiresAt': download.expiresAt.toIso8601String(),
          'mimeType': download.mimeType,
          'title': download.title,
        }),
      );
    } catch (_) {}
  }
}
