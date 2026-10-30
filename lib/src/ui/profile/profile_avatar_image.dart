import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:student_platform/src/config/supabase_config.dart';

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
      maxWidth: 264,
      maxHeight: 264);
}
