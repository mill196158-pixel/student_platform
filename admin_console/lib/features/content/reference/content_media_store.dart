import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of a successful content-media upload finalize.
class ContentMediaUploadResult {
  const ContentMediaUploadResult({
    required this.assetId,
    this.workingDraftId,
    this.workingDraftRowVersion,
  });

  final String assetId;
  final String? workingDraftId;
  final int? workingDraftRowVersion;
}

/// Admin helper for Stage 16.3 / 14.2.1 content-media signed upload.
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
    final result = await uploadBytesDetailed(
      contentItemId: contentItemId,
      bytes: bytes,
      contentType: contentType,
      title: title,
    );
    return result.assetId;
  }

  Future<ContentMediaUploadResult> uploadBytesDetailed({
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
      throw StateError(_functionError(create, 'createUpload'));
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
      throw StateError(_functionError(finalize, 'finalizeUpload'));
    }
    final asset = Map<String, dynamic>.from(
      (finalize.data as Map)['asset'] as Map,
    );
    final id = (asset['id'] ?? '').toString();
    if (id.isEmpty) throw StateError('finalize missing asset id');
    final draftRvRaw = asset['working_draft_row_version'];
    final draftRv = draftRvRaw is int
        ? draftRvRaw
        : int.tryParse(draftRvRaw?.toString() ?? '');
    return ContentMediaUploadResult(
      assetId: id,
      workingDraftId:
          (asset['working_draft_id'] ?? '').toString().trim().isEmpty
          ? null
          : (asset['working_draft_id'] ?? '').toString().trim(),
      workingDraftRowVersion: draftRv,
    );
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

  String _functionError(FunctionResponse response, String action) {
    final data = response.data;
    String code = '';
    if (data is Map) {
      code = (data['error'] ?? '').toString().trim();
    }
    if (code.isEmpty) return '$action failed: ${response.status}';
    return '$action failed: ${response.status} ($code)';
  }
}
