import 'package:student_ui/student_ui.dart';

enum ReferenceArticleStatus { draft, published, archived }

ReferenceArticleStatus? parseReferenceArticleStatus(Object? raw) {
  switch (raw?.toString()) {
    case 'draft':
      return ReferenceArticleStatus.draft;
    case 'published':
      return ReferenceArticleStatus.published;
    case 'archived':
      return ReferenceArticleStatus.archived;
    default:
      return null;
  }
}

String referenceArticleStatusWire(ReferenceArticleStatus status) {
  switch (status) {
    case ReferenceArticleStatus.draft:
      return 'draft';
    case ReferenceArticleStatus.published:
      return 'published';
    case ReferenceArticleStatus.archived:
      return 'archived';
  }
}

enum ReferenceCategoryStatus { draft, published, archived }

ReferenceCategoryStatus? parseReferenceCategoryStatus(Object? raw) {
  switch (raw?.toString()) {
    case 'draft':
      return ReferenceCategoryStatus.draft;
    case 'published':
      return ReferenceCategoryStatus.published;
    case 'archived':
      return ReferenceCategoryStatus.archived;
    default:
      return null;
  }
}

class ReferenceCategoryItem {
  const ReferenceCategoryItem({
    required this.id,
    required this.title,
    required this.iconKey,
    required this.sortOrder,
    required this.rowVersion,
    this.key,
    this.status = ReferenceCategoryStatus.published,
  });

  final String id;
  final String? key;
  final String title;
  final String iconKey;
  final int sortOrder;
  final int rowVersion;
  final ReferenceCategoryStatus status;

  static ReferenceCategoryItem? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id']?.toString();
    final title = json['title']?.toString();
    final iconKey = (json['icon_key'] ?? json['iconKey'])?.toString();
    if (id == null || id.isEmpty || title == null || iconKey == null) {
      return null;
    }
    return ReferenceCategoryItem(
      id: id,
      key: json['key']?.toString(),
      title: title,
      iconKey: iconKey,
      sortOrder: _asInt(json['sort_order']) ?? 0,
      rowVersion: _asInt(json['row_version']) ?? 1,
      status:
          parseReferenceCategoryStatus(json['status']) ??
          ReferenceCategoryStatus.published,
    );
  }

  ReferenceCategoryItem copyWith({
    String? title,
    String? iconKey,
    int? sortOrder,
    int? rowVersion,
    ReferenceCategoryStatus? status,
  }) {
    return ReferenceCategoryItem(
      id: id,
      key: key,
      title: title ?? this.title,
      iconKey: iconKey ?? this.iconKey,
      sortOrder: sortOrder ?? this.sortOrder,
      rowVersion: rowVersion ?? this.rowVersion,
      status: status ?? this.status,
    );
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }
}

class ReferenceArticleItem {
  const ReferenceArticleItem({
    required this.id,
    required this.status,
    required this.origin,
    required this.title,
    required this.payload,
    required this.categoryId,
    required this.rowVersion,
    required this.sortOrder,
    required this.audienceMode,
    this.categoryTitle,
    this.legacyKey,
    this.audienceGroupIds = const [],
    this.audienceUserIds = const [],
  });

  final String id;
  final ReferenceArticleStatus status;
  final ContentOrigin origin;
  final String title;
  final ReferenceArticlePayload payload;
  final String categoryId;
  final String? categoryTitle;

  /// Stable Stage 14.1 bootstrap identity. It is retained after demo promotion.
  final String? legacyKey;
  final int rowVersion;
  final int sortOrder;
  final String audienceMode;
  final List<String> audienceGroupIds;
  final List<String> audienceUserIds;

  static ReferenceArticleItem? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id']?.toString();
    final status = parseReferenceArticleStatus(json['status']);
    final origin = ContentOrigin.tryParse(json['origin']);
    if (id == null || id.isEmpty || status == null || origin == null) {
      return null;
    }
    final schemaVersion = _asInt(json['schema_version']) ?? 2;
    final payloadRaw = json['payload'];
    if (payloadRaw is! Map) return null;
    final payload = ReferenceArticlePayload.tryParseForSchema(
      schemaVersion,
      Map<String, dynamic>.from(payloadRaw),
    );
    if (payload == null) return null;
    final categoryId =
        (json['category_id'] ??
                json['reference_category_id'] ??
                json['referenceCategoryId'])
            ?.toString();
    if (categoryId == null || categoryId.isEmpty) return null;
    final title = (json['title'] ?? payload.shortText).toString();
    var sortOrder = _asInt(json['sort_order']) ?? 0;
    final placements = json['placements'];
    if (placements is List) {
      for (final p in placements.whereType<Map>()) {
        if (p['placement']?.toString() == 'reference') {
          sortOrder = _asInt(p['sort_order']) ?? sortOrder;
          break;
        }
      }
    }
    return ReferenceArticleItem(
      id: id,
      status: status,
      origin: origin,
      title: title,
      payload: payload,
      categoryId: categoryId,
      categoryTitle: json['category_title']?.toString(),
      legacyKey: json['legacy_key']?.toString(),
      rowVersion: _asInt(json['row_version']) ?? 1,
      sortOrder: sortOrder,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      audienceGroupIds: _asIdList(json['audience_group_ids']),
      audienceUserIds: _asIdList(json['audience_user_ids']),
    );
  }

  ReferenceArticleItem copyWith({
    ReferenceArticleStatus? status,
    ContentOrigin? origin,
    String? title,
    ReferenceArticlePayload? payload,
    String? categoryId,
    String? categoryTitle,
    String? legacyKey,
    int? rowVersion,
    int? sortOrder,
    String? audienceMode,
    List<String>? audienceGroupIds,
    List<String>? audienceUserIds,
  }) {
    return ReferenceArticleItem(
      id: id,
      status: status ?? this.status,
      origin: origin ?? this.origin,
      title: title ?? this.title,
      payload: payload ?? this.payload,
      categoryId: categoryId ?? this.categoryId,
      categoryTitle: categoryTitle ?? this.categoryTitle,
      legacyKey: legacyKey ?? this.legacyKey,
      rowVersion: rowVersion ?? this.rowVersion,
      sortOrder: sortOrder ?? this.sortOrder,
      audienceMode: audienceMode ?? this.audienceMode,
      audienceGroupIds: audienceGroupIds ?? this.audienceGroupIds,
      audienceUserIds: audienceUserIds ?? this.audienceUserIds,
    );
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  static List<String> _asIdList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }
}

class ReferenceCorrectionItem {
  const ReferenceCorrectionItem({
    required this.id,
    required this.contentItemId,
    required this.contentTitle,
    required this.note,
    required this.status,
    this.resolutionNote,
    this.createdAt,
  });

  final String id;
  final String contentItemId;
  final String contentTitle;
  final String note;
  final String status;
  final String? resolutionNote;
  final DateTime? createdAt;

  static ReferenceCorrectionItem? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = json['id']?.toString();
    final note = json['note']?.toString();
    final status = json['status']?.toString();
    if (id == null || note == null || status == null) return null;
    return ReferenceCorrectionItem(
      id: id,
      contentItemId: json['content_item_id']?.toString() ?? '',
      contentTitle: json['content_title']?.toString() ?? '',
      note: note,
      status: status,
      resolutionNote: json['resolution_note']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}
