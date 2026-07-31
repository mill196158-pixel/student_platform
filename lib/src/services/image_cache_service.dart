import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

class AppImageCache {
  static final AppImageCache _instance = AppImageCache._internal();
  factory AppImageCache() => _instance;
  AppImageCache._internal();

  // Tuned LRU cache: ~200 objects, 14 days TTL
  late final CacheManager manager = CacheManager(
    Config(
      'app_image_cache_v1',
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 200,
      repo: JsonCacheInfoRepository(databaseName: 'app_image_cache.db'),
      fileService: HttpFileService(),
    ),
  );

  Future<void> prefetchUrls(Iterable<String> urls) async {
    final unique = <String>{}..addAll(urls.where((u) => u.isNotEmpty));
    for (final url in unique) {
      // fire-and-forget
      CachedNetworkImageProvider(url, cacheManager: manager).resolve(const ImageConfiguration());
    }
  }
}


