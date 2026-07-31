import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SubjectMediaDownload {
  const SubjectMediaDownload({
    required this.signedUrl,
    required this.expiresAt,
  });

  final String signedUrl;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool get shouldRefresh {
    if (isExpired) return true;
    return expiresAt.difference(DateTime.now()) < const Duration(minutes: 1);
  }
}

/// Mobile signed-download helper for subject card assets (Stage 16.2).
class SubjectMediaService {
  SubjectMediaService({
    SupabaseClient? client,
    http.Client? httpClient,
    NewsImageBytesCache? bytesCache,
    Future<SharedPreferences> Function()? prefs,
    String? Function()? currentUserId,
  })  : _client = client,
        _http = httpClient ?? http.Client(),
        _bytesCache = bytesCache ?? NewsImageBytesCache.instance,
        _prefs = prefs ?? SharedPreferences.getInstance,
        _currentUserId = currentUserId;

  final SupabaseClient? _client;
  SupabaseClient get _sb => _client ?? Supabase.instance.client;
  final http.Client _http;
  final NewsImageBytesCache _bytesCache;
  final Future<SharedPreferences> Function() _prefs;
  final String? Function()? _currentUserId;

  static const _function = 'subject-media';
  static const _urlCachePrefix = 'subject_media_url_v1';

  final Map<String, SubjectMediaDownload> _memoryUrls = {};

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

  String _urlKey(String offeringId, String assetId) =>
      '$_userScope|$offeringId|$assetId';

  NewsImageCacheKey bytesCacheKey(String offeringId, SubjectCardAsset asset) {
    return NewsImageCacheKey(
      path: 'subject|$_userScope|$offeringId|${asset.id}',
      version: '${asset.versionNumber}',
    );
  }

  Future<Uint8List?> fetchAssetBytes({
    required SubjectCardAsset asset,
    required String subjectOfferingId,
  }) async {
    final offeringId = subjectOfferingId.trim();
    if (offeringId.isEmpty) return null;

    final cacheKey = bytesCacheKey(offeringId, asset);
    return _bytesCache.getOrFetch(cacheKey, () async {
      final download = await _resolveDownload(
        assetId: asset.id,
        subjectOfferingId: offeringId,
      );
      if (download == null) return null;
      try {
        final response = await _http.get(Uri.parse(download.signedUrl));
        if (response.statusCode == 403 || response.statusCode == 401) {
          await clearAsset(offeringId, asset);
          return null;
        }
        if (response.statusCode != 200) return null;
        final bytes = response.bodyBytes;
        return bytes.isEmpty ? null : bytes;
      } catch (e) {
        debugPrint('[subject_media] download failed type=${e.runtimeType}');
        return null;
      }
    });
  }

  /// Public for Web attachment open (launch signed URL without dart:io).
  Future<SubjectMediaDownload?> resolveDownload({
    required String assetId,
    required String subjectOfferingId,
  }) =>
      _resolveDownload(
        assetId: assetId,
        subjectOfferingId: subjectOfferingId,
      );

  Future<SubjectMediaDownload?> _resolveDownload({
    required String assetId,
    required String subjectOfferingId,
  }) async {
    final memKey = _urlKey(subjectOfferingId, assetId);
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
          'assetId': assetId,
          'offeringId': subjectOfferingId,
        },
      );
      if (response.status == 403 || response.status == 401) {
        await clearAssetById(subjectOfferingId, assetId);
        return null;
      }
      if (response.status >= 400) return null;
      final data = response.data;
      if (data is! Map) return null;
      if (responseLeaksStoragePath(data)) {
        debugPrint('[subject_media] createDownload leaked path — rejected');
        return null;
      }
      final signedUrl = (data['signedUrl'] ?? '').toString();
      if (signedUrl.isEmpty) return null;
      final expiresIn = int.tryParse('${data['expiresIn'] ?? 3600}') ?? 3600;
      final download = SubjectMediaDownload(
        signedUrl: signedUrl,
        expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      );
      _memoryUrls[memKey] = download;
      await _writePersistedUrl(memKey, download);
      return download;
    } on PostgrestException catch (error) {
      if (_isAccessDenied(error)) {
        await clearAssetById(subjectOfferingId, assetId);
      }
      return null;
    } catch (e) {
      debugPrint('[subject_media] createDownload failed type=${e.runtimeType}');
      return null;
    }
  }

  Future<void> clearAll() async {
    _memoryUrls.clear();
    _bytesCache.clear();
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

  Future<void> clearAsset(String offeringId, SubjectCardAsset asset) {
    return clearAssetById(
      offeringId,
      asset.id,
      versionNumber: asset.versionNumber,
    );
  }

  Future<void> clearAssetById(
    String offeringId,
    String assetId, {
    int? versionNumber,
  }) async {
    final memKey = _urlKey(offeringId, assetId);
    _memoryUrls.remove(memKey);
    if (versionNumber != null) {
      _bytesCache.invalidateKey(
        NewsImageCacheKey(
          path: 'subject|$_userScope|$offeringId|$assetId',
          version: '$versionNumber',
        ),
      );
    } else {
      _bytesCache.invalidatePath('subject|$_userScope|$offeringId|$assetId');
    }
    try {
      final prefs = await _prefs();
      await prefs.remove('${_urlCachePrefix}__$memKey');
    } catch (_) {}
  }

  Future<SubjectMediaDownload?> _readPersistedUrl(String memKey) async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString('${_urlCachePrefix}__$memKey');
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final url = (map['signedUrl'] ?? '').toString();
      final expiresRaw = map['expiresAt']?.toString();
      if (url.isEmpty || expiresRaw == null) return null;
      final expiresAt = DateTime.tryParse(expiresRaw);
      if (expiresAt == null) return null;
      return SubjectMediaDownload(signedUrl: url, expiresAt: expiresAt);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePersistedUrl(
    String memKey,
    SubjectMediaDownload download,
  ) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(
        '${_urlCachePrefix}__$memKey',
        jsonEncode({
          'signedUrl': download.signedUrl,
          'expiresAt': download.expiresAt.toUtc().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  /// Fail-closed: Edge must never return storage path keys to Mobile.
  static bool responseLeaksStoragePath(Map data) {
    return data.containsKey('path') || data.containsKey('storage_path');
  }

  static bool _isAccessDenied(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    if (code == '42501' || code == '28000' || code == 'P0002') return true;
    final message = error.message.toLowerCase();
    return message.contains('forbidden') ||
        message.contains('not_authenticated') ||
        message.contains('download denied');
  }
}
