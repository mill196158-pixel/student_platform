import 'dart:convert';

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

/// Mobile signed-download helper for Stage 17 vacancy assets (`vacancy-media` Edge).
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
  static const _urlCachePrefix = 'vacancy_media_url_v1';

  final Map<String, VacancyMediaDownload> _memoryUrls = {};

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

  String _urlKey(String assetId) => '$_userScope|$assetId';

  Future<VacancyMediaDownload?> resolveDownload(String assetId) async {
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

  Future<void> clearAll() async {
    _memoryUrls.clear();
    try {
      final prefs = await _prefs();
      final scope = _userScope;
      for (final key in prefs.getKeys()) {
        if (key.startsWith('$_urlCachePrefix|') && key.contains('$scope|')) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  Future<String?> openAsset(String assetId) async {
    final download = await resolveDownload(assetId);
    if (download == null) return null;
    return download.signedUrl;
  }

  Future<VacancyMediaDownload?> _readPersistedUrl(String key) async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString('$_urlCachePrefix|$key');
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
