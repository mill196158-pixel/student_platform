import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Admin helper for Stage 16.3 content-media signed upload.
class ContentMediaStore {
  ContentMediaStore({SupabaseClient? client, http.Client? httpClient})
    : _client = client,
      _http = httpClient ?? http.Client();

  final SupabaseClient? _client;
  final http.Client _http;

  SupabaseClient get _sb => _client ?? Supabase.instance.client;

  Future<String> uploadBytes({
    required String contentItemId,
    required Uint8List bytes,
    required String contentType,
    String title = '',
  }) async {
    final create = await _sb.functions.invoke(
      'content-media',
      body: {
        'action': 'createUpload',
        'contentItemId': contentItemId,
        'contentType': contentType,
        'fileSize': bytes.length,
      },
    );
    if (create.status >= 400) {
      throw StateError('createUpload failed: ${create.status}');
    }
    final data = Map<String, dynamic>.from(create.data as Map);
    final signedUrl = (data['signedUrl'] ?? '').toString();
    final intentId = (data['intentId'] ?? '').toString();
    if (signedUrl.isEmpty || intentId.isEmpty) {
      throw StateError('createUpload missing fields');
    }
    // Fail closed if Edge ever leaks a storage path to the Admin client.
    final leakedPath =
        (data['path'] ?? data['storage_path'] ?? data['storagePath'])
            ?.toString()
            .trim();
    if (leakedPath != null && leakedPath.isNotEmpty) {
      throw StateError('createUpload leaked storage path');
    }
    final put = await _http.put(
      Uri.parse(signedUrl),
      headers: {'Content-Type': contentType},
      body: bytes,
    );
    if (put.statusCode >= 400) {
      throw StateError('storage put failed: ${put.statusCode}');
    }
    final finalize = await _sb.functions.invoke(
      'content-media',
      body: {'action': 'finalizeUpload', 'intentId': intentId, 'title': title},
    );
    if (finalize.status >= 400) {
      throw StateError('finalizeUpload failed: ${finalize.status}');
    }
    final asset = Map<String, dynamic>.from(
      (finalize.data as Map)['asset'] as Map,
    );
    final id = (asset['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('finalize missing asset id');
    return id;
  }

  Future<Uint8List?> downloadBytes({required String assetId}) async {
    final download = await _sb.functions.invoke(
      'content-media',
      body: {'action': 'createDownload', 'assetId': assetId},
    );
    if (download.status >= 400) return null;
    final data = Map<String, dynamic>.from(download.data as Map);
    final signedUrl = (data['signedUrl'] ?? '').toString();
    if (signedUrl.isEmpty) return null;
    final response = await _http.get(Uri.parse(signedUrl));
    if (response.statusCode != 200) return null;
    return response.bodyBytes;
  }
}
