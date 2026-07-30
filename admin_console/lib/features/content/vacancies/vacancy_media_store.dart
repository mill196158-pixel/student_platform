import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Admin helper for Stage 17 vacancy-media signed upload.
class VacancyMediaStore {
  VacancyMediaStore({SupabaseClient? client, http.Client? httpClient})
      : _client = client,
        _http = httpClient ?? http.Client();

  final SupabaseClient? _client;
  final http.Client _http;

  SupabaseClient get _sb => _client ?? Supabase.instance.client;

  Future<String> uploadBytes({
    required String vacancyId,
    required Uint8List bytes,
    required String contentType,
    String title = '',
  }) async {
    final create = await _sb.functions.invoke(
      'vacancy-media',
      body: {
        'action': 'createUpload',
        'vacancyId': vacancyId,
        'contentType': contentType,
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
    final leakedPath = (data['path'] ?? data['storage_path'] ?? data['storagePath'])
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
      'vacancy-media',
      body: {
        'action': 'finalizeUpload',
        'intentId': intentId,
        'title': title,
      },
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
}
