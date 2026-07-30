import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Admin-side subject asset row (descriptor only — no storage paths).
class SubjectMediaAssetRow {
  const SubjectMediaAssetRow({
    required this.id,
    required this.title,
    required this.mimeType,
    required this.byteSize,
    required this.versionNumber,
    required this.kind,
    required this.logicalAssetId,
    required this.isCurrent,
  });

  final String id;
  final String title;
  final String mimeType;
  final int byteSize;
  final int versionNumber;
  final SubjectCardAssetKind kind;
  final String logicalAssetId;
  final bool isCurrent;

  SubjectCardAsset toDescriptor() => SubjectCardAsset(
        id: id,
        title: title,
        mimeType: mimeType,
        byteSize: byteSize,
        versionNumber: versionNumber,
        kind: kind,
        logicalAssetId: logicalAssetId,
      );

  static SubjectMediaAssetRow? fromJson(Map<String, dynamic> json) {
    final asset = SubjectCardAsset.tryParse(json);
    if (asset == null) return null;
    final isCurrent =
        json['is_current'] == true || json['isCurrent'] == true;
    return SubjectMediaAssetRow(
      id: asset.id,
      title: asset.title,
      mimeType: asset.mimeType,
      byteSize: asset.byteSize,
      versionNumber: asset.versionNumber,
      kind: asset.kind,
      logicalAssetId: asset.logicalAssetId,
      isCurrent: isCurrent,
    );
  }
}

/// Result of a completed subject-media upload.
class UploadedSubjectMedia {
  const UploadedSubjectMedia({
    required this.assetId,
    required this.logicalAssetId,
    required this.kind,
  });

  final String assetId;
  final String logicalAssetId;
  final SubjectCardAssetKind kind;
}

abstract class SubjectMediaStore {
  Future<List<SubjectMediaAssetRow>> listAssets({
    String? subjectCatalogId,
    String? subjectOfferingId,
    bool currentOnly = true,
  });

  Future<UploadedSubjectMedia> uploadBytes({
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
    required SubjectCardAssetKind kind,
    String? subjectCatalogId,
    String? subjectOfferingId,
    String? logicalAssetId,
    String? supersedesAssetId,
    String title = '',
  });

  Future<void> deleteAsset(String assetId);

  Future<Uint8List?> downloadBytes({
    required String assetId,
    required String subjectOfferingId,
    required int versionNumber,
  });

  void clearPrivateCache();
}

/// Supabase adapter for private `subject-media` bucket via Edge function.
class SupabaseSubjectMediaStore implements SubjectMediaStore {
  SupabaseSubjectMediaStore({
    SupabaseClient? client,
    http.Client? httpClient,
    NewsImageBytesCache? cache,
  })  : _client = client ?? Supabase.instance.client,
        _http = httpClient ?? http.Client(),
        _cache = cache ?? NewsImageBytesCache.instance;

  final SupabaseClient _client;
  final http.Client _http;
  final NewsImageBytesCache _cache;

  static const _bucket = 'subject-media';
  static const _function = 'subject-media';

  @override
  void clearPrivateCache() => _cache.clear();

  @override
  Future<List<SubjectMediaAssetRow>> listAssets({
    String? subjectCatalogId,
    String? subjectOfferingId,
    bool currentOnly = true,
  }) async {
    _assertOwner(subjectCatalogId, subjectOfferingId);
    final result = await _client.rpc(
      'admin_list_subject_assets',
      params: {
        'p_subject_catalog_id': subjectCatalogId,
        'p_subject_offering_id': subjectOfferingId,
        'p_current_only': currentOnly,
      },
    );
    final list = _asList(result);
    final out = <SubjectMediaAssetRow>[];
    for (final row in list) {
      final parsed = SubjectMediaAssetRow.fromJson(row);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }

  @override
  Future<UploadedSubjectMedia> uploadBytes({
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
    required SubjectCardAssetKind kind,
    String? subjectCatalogId,
    String? subjectOfferingId,
    String? logicalAssetId,
    String? supersedesAssetId,
    String title = '',
  }) async {
    _assertOwner(subjectCatalogId, subjectOfferingId);
    final upload = await _invoke({
      'action': 'createUpload',
      'subjectCatalogId': subjectCatalogId,
      'subjectOfferingId': subjectOfferingId,
      'assetKind': kind.wireValue,
      'contentType': mimeType,
      'fileSize': bytes.length,
      if (logicalAssetId != null) 'logicalAssetId': logicalAssetId,
    });

    final path = (upload['path'] ?? '').toString();
    final token = (upload['token'] ?? '').toString();
    final intentId = (upload['intentId'] ?? '').toString();
    if (path.isEmpty || token.isEmpty || intentId.isEmpty) {
      throw StateError('Не удалось зарезервировать загрузку subject-media.');
    }

    await _client.storage.from(_bucket).uploadBinaryToSignedUrl(
          path,
          token,
          bytes,
          FileOptions(contentType: mimeType, upsert: true),
        );

    final finalized = await _invoke({
      'action': 'finalizeUpload',
      'intentId': intentId,
      'title': title,
      if (supersedesAssetId != null) 'supersedesAssetId': supersedesAssetId,
    });

    final asset = finalized['asset'];
    if (asset is! Map) {
      throw StateError('subject-media finalize: некорректный ответ.');
    }
    final map = Map<String, dynamic>.from(asset);
    final id = '${map['id'] ?? ''}';
    final logical = '${map['logical_asset_id'] ?? map['logicalAssetId'] ?? ''}';
    final parsedKind = SubjectCardAssetKind.tryParse(
      map['asset_kind'] ?? map['assetKind'],
    );
    if (id.isEmpty || logical.isEmpty || parsedKind == null) {
      throw StateError('subject-media finalize: дескriptor неполный.');
    }

    final version = int.tryParse('${map['version_number'] ?? 1}') ?? 1;
    _cache.put(
      NewsImageCacheKey(path: '$id|$subjectCatalogId|$subjectOfferingId', version: '$version'),
      bytes,
    );

    return UploadedSubjectMedia(
      assetId: id,
      logicalAssetId: logical,
      kind: parsedKind,
    );
  }

  @override
  Future<void> deleteAsset(String assetId) async {
    if (assetId.trim().isEmpty) return;
    await _client.rpc(
      'admin_delete_subject_asset',
      params: {'p_asset_id': assetId},
    );
  }

  @override
  Future<Uint8List?> downloadBytes({
    required String assetId,
    required String subjectOfferingId,
    required int versionNumber,
  }) async {
    final key = NewsImageCacheKey(
      path: '$assetId|$subjectOfferingId',
      version: '$versionNumber',
    );
    return _cache.getOrFetch(key, () async {
      final download = await _invoke({
        'action': 'createDownload',
        'assetId': assetId,
        'offeringId': subjectOfferingId,
      });
      final signedUrl = (download['signedUrl'] ?? '').toString();
      if (signedUrl.isEmpty) return null;
      final response = await _http.get(Uri.parse(signedUrl));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    });
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    final response = await _client.functions.invoke(_function, body: body);
    if (response.status >= 400) {
      throw StateError(
        'subject-media Edge недоступен (${response.status}). '
        'Локальный Edge должен быть запущен.',
      );
    }
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw StateError('Некорректный ответ subject-media Edge.');
  }

  static void _assertOwner(String? catalogId, String? offeringId) {
    final hasCatalog = catalogId != null && catalogId.trim().isNotEmpty;
    final hasOffering = offeringId != null && offeringId.trim().isNotEmpty;
    if (hasCatalog == hasOffering) {
      throw ArgumentError(
        'Exactly one of subjectCatalogId or subjectOfferingId is required.',
      );
    }
  }

  static List<Map<String, dynamic>> _asList(dynamic data) {
    dynamic value = data;
    if (value is String && value.isNotEmpty) {
      value = jsonDecode(value);
    }
    if (value is! List) return const [];
    return value
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
}

/// In-memory fake for widget/unit tests (no network).
class FakeSubjectMediaStore implements SubjectMediaStore {
  final Map<String, List<SubjectMediaAssetRow>> _byOwner = {};
  int _next = 1;

  @override
  void clearPrivateCache() {}

  String _ownerKey({String? catalogId, String? offeringId}) {
    return catalogId ?? offeringId ?? 'unknown';
  }

  @override
  Future<List<SubjectMediaAssetRow>> listAssets({
    String? subjectCatalogId,
    String? subjectOfferingId,
    bool currentOnly = true,
  }) async {
    final key = _ownerKey(
      catalogId: subjectCatalogId,
      offeringId: subjectOfferingId,
    );
    final rows = _byOwner[key] ?? const [];
    if (!currentOnly) return List.from(rows);
    return rows.where((r) => r.isCurrent).toList();
  }

  @override
  Future<UploadedSubjectMedia> uploadBytes({
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
    required SubjectCardAssetKind kind,
    String? subjectCatalogId,
    String? subjectOfferingId,
    String? logicalAssetId,
    String? supersedesAssetId,
    String title = '',
  }) async {
    final key = _ownerKey(
      catalogId: subjectCatalogId,
      offeringId: subjectOfferingId,
    );
    final logical = logicalAssetId ?? 'logical-$_next';
    final id = 'asset-${_next++}';
    final row = SubjectMediaAssetRow(
      id: id,
      title: title,
      mimeType: mimeType,
      byteSize: bytes.length,
      versionNumber: 1,
      kind: kind,
      logicalAssetId: logical,
      isCurrent: true,
    );
    _byOwner.putIfAbsent(key, () => []).add(row);
    return UploadedSubjectMedia(
      assetId: id,
      logicalAssetId: logical,
      kind: kind,
    );
  }

  @override
  Future<void> deleteAsset(String assetId) async {
    for (final entry in _byOwner.entries) {
      entry.value.removeWhere((r) => r.id == assetId);
    }
  }

  @override
  Future<Uint8List?> downloadBytes({
    required String assetId,
    required String subjectOfferingId,
    required int versionNumber,
  }) async {
    return Uint8List.fromList([1, 2, 3]);
  }
}
