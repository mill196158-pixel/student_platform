import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:student_platform/src/config/supabase_config.dart';

const _avatarDimension = 264;
const _maxSavedAvatarBytes = 2 * 1024 * 1024;

/// Only call with the authenticated owner's validated profile. The account and
/// full versioned URL scope both the disk cache and Flutter's decoded cache.
ImageProvider? profileAvatarImage(String? userId, String? avatarUrl,
    {BaseCacheManager? cacheManager,
    String storageOrigin = SupabaseConfig.url}) {
  final uid = userId?.trim() ?? '';
  final url = avatarUrl?.trim() ?? '';
  final uri = Uri.tryParse(url);
  if (uid.isEmpty ||
      uri == null ||
      !uri.hasAuthority ||
      (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  // Only our public avatar objects get new persistent disk caching. Other
  // URLs retain NetworkImage behavior (including its decoded memory cache).
  final origin = Uri.tryParse(storageOrigin);
  if (origin == null ||
      uri.origin != origin.origin ||
      uri.queryParameters.keys.any((key) => key != 'v') ||
      !uri.path.startsWith('/storage/v1/object/public/avatars/')) {
    return NetworkImage(url);
  }
  return CachedNetworkImageProvider(url,
      cacheManager: cacheManager,
      cacheKey: 'profile-avatar-v1:$uid:$url',
      maxWidth: _avatarDimension,
      maxHeight: _avatarDimension);
}

/// Reads existing app-owned copies without starting a new network request.
Future<Uint8List?> readSavedProfileAvatar(
  String userId,
  String avatarUrl, {
  required bool Function() isCurrent,
  BaseCacheManager? cacheManager,
}) async {
  if (kIsWeb || !isCurrent()) return null;
  final provider = profileAvatarImage(userId, avatarUrl);
  if (provider is! CachedNetworkImageProvider || provider.cacheKey == null) {
    return null;
  }
  final key = provider.cacheKey!;
  final manager = cacheManager ?? DefaultCacheManager();
  // CacheManager stores this exact dimension-qualified key when a resize
  // is needed. Smaller originals may exist only at the unqualified key.
  for (final candidate in [
    'resized_w${_avatarDimension}_h${_avatarDimension}_$key',
    key,
  ]) {
    try {
      final entry = await manager.getFileFromCache(candidate);
      if (!isCurrent()) return null;
      if (entry == null || entry.originalUrl != provider.url) continue;
      final buffer = BytesBuilder(copy: false);
      await for (final chunk
          in entry.file.openRead(0, _maxSavedAvatarBytes + 1)) {
        if (!isCurrent()) return null;
        buffer.add(chunk);
      }
      if (isCurrent() &&
          buffer.isNotEmpty &&
          buffer.length <= _maxSavedAvatarBytes) {
        return buffer.takeBytes();
      }
    } catch (_) {
      if (!isCurrent()) return null;
    }
  }
  return null;
}
