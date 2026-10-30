import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:student_ui/student_ui.dart';
import '../../config/supabase_config.dart';
import '../home/news_image_disk_cache.dart';

/// Public projection only. Never attaches the signed-in account's JWT.
class GuestPublicService {
  final _client = http.Client();
  final _images = NewsImageDiskCache(directoryName: 'guest_news_images_v1');
  Map<String, String> get _headers =>
      {'apikey': SupabaseConfig.anonKey, 'Content-Type': 'application/json'};
  Future<List<Map<String, dynamic>>> rpc(String name,
      [Map<String, dynamic> params = const {}]) async {
    final response = await _client
        .post(Uri.parse('${SupabaseConfig.url}/rest/v1/rpc/$name'),
            headers: _headers, body: jsonEncode(params))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) throw StateError('Public data unavailable');
    return (jsonDecode(response.body) as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  Future<Uint8List?> image(Map<String, dynamic> row) async {
    final path = row['image_path'] as String?;
    if (path == null || path.isEmpty) return null;
    final key = NewsImageCacheKey(
        path: 'guest/$path',
        version: '${row['version_number']}:${row['updated_at']}');
    return _images.getOrFetch(key, () async {
      final link = await _client
          .post(
              Uri.parse('${SupabaseConfig.url}/functions/v1/guest-news-media'),
              headers: _headers,
              body: jsonEncode({'id': row['id']}))
          .timeout(const Duration(seconds: 12));
      if (link.statusCode != 200) return null;
      final url = jsonDecode(link.body)['signedUrl'] as String;
      final response = await _client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 5 * 1024 * 1024) return null;
      return response.bodyBytes;
    });
  }

  void dispose() => _client.close();
}
