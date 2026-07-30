import 'package:student_ui/student_ui.dart';

enum HomePromoStatus { draft, published, archived }

HomePromoStatus? parseHomePromoStatus(Object? raw) {
  switch (raw?.toString()) {
    case 'draft':
      return HomePromoStatus.draft;
    case 'published':
      return HomePromoStatus.published;
    case 'archived':
      return HomePromoStatus.archived;
    default:
      return null;
  }
}

String homePromoStatusWire(HomePromoStatus status) {
  switch (status) {
    case HomePromoStatus.draft:
      return 'draft';
    case HomePromoStatus.published:
      return 'published';
    case HomePromoStatus.archived:
      return 'archived';
  }
}

int? _homePromoAsInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '');
}

DateTime? _homePromoAsDate(Object? raw) {
  if (raw == null) return null;
  return DateTime.tryParse(raw.toString());
}

extension HomePromoStatusLabel on HomePromoStatus {
  String get russianLabel => switch (this) {
    HomePromoStatus.draft => 'Черновик',
    HomePromoStatus.published => 'Опубликован',
    HomePromoStatus.archived => 'В архиве',
  };
}

class HomePromoVersionInfo {
  const HomePromoVersionInfo({
    required this.versionNumber,
    this.createdAt,
    this.title = '',
    this.status,
  });

  final int versionNumber;
  final DateTime? createdAt;
  final String title;
  final HomePromoStatus? status;

  factory HomePromoVersionInfo.fromJson(Map<String, dynamic> json) {
    final snapshot = json['snapshot'];
    String title = '';
    HomePromoStatus? status;
    if (snapshot is Map) {
      title = (snapshot['title'] ?? '').toString();
      status = parseHomePromoStatus(snapshot['status']);
    }
    return HomePromoVersionInfo(
      versionNumber: _homePromoAsInt(json['version_number']) ?? 0,
      createdAt: _homePromoAsDate(json['created_at']),
      title: title,
      status: status,
    );
  }
}

class HomePromoSafeDeleteResult {
  const HomePromoSafeDeleteResult({
    required this.id,
    this.legacyKey,
    this.queuedMedia = 0,
  });

  final String id;
  final String? legacyKey;
  final int queuedMedia;

  factory HomePromoSafeDeleteResult.fromJson(Map<String, dynamic> json) {
    return HomePromoSafeDeleteResult(
      id: json['id']?.toString() ?? '',
      legacyKey: json['legacy_key']?.toString(),
      queuedMedia: _homePromoAsInt(json['queued_media']) ?? 0,
    );
  }
}

class HomePromoAudiencePreview {
  const HomePromoAudiencePreview({
    required this.recipientCount,
    required this.audienceMode,
    this.groupCount = 0,
    this.explicitUserCount = 0,
  });

  final int recipientCount;
  final String audienceMode;
  final int groupCount;
  final int explicitUserCount;

  factory HomePromoAudiencePreview.fromJson(Map<String, dynamic> json) {
    final breakdown = json['breakdown'];
    final breakdownMap = breakdown is Map
        ? Map<String, dynamic>.from(breakdown)
        : const {};
    final groups = breakdownMap['groups'];
    final groupCount = groups is List
        ? groups.length
        : int.tryParse('${json['group_count'] ?? 0}') ?? 0;
    final explicit =
        int.tryParse(
          '${breakdownMap['explicit_users_count'] ?? json['explicit_users_count'] ?? 0}',
        ) ??
        0;
    return HomePromoAudiencePreview(
      recipientCount: int.tryParse('${json['recipient_count'] ?? 0}') ?? 0,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      groupCount: groupCount,
      explicitUserCount: explicit,
    );
  }
}

class HomePromoItem {
  const HomePromoItem({
    required this.id,
    required this.status,
    required this.origin,
    required this.title,
    required this.payload,
    required this.rowVersion,
    required this.priority,
    required this.sortOrder,
    required this.audienceMode,
    this.templateKey = 'home_promo_v1',
    this.schemaVersion = 1,
    this.versionNumber = 1,
    this.isHidden = false,
    this.legacyKey,
    this.startsAt,
    this.endsAt,
    this.audienceGroupIds = const [],
    this.audienceUserIds = const [],
  });

  final String id;
  final HomePromoStatus status;
  final ContentOrigin origin;
  final String title;
  final HomePromoPayload payload;
  final int rowVersion;
  final int priority;
  final int sortOrder;
  final String audienceMode;
  final String templateKey;
  final int schemaVersion;
  final int versionNumber;
  final bool isHidden;
  final String? legacyKey;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final List<String> audienceGroupIds;
  final List<String> audienceUserIds;

  bool get isDraft => status == HomePromoStatus.draft;
  bool get isPublished => status == HomePromoStatus.published;
  bool get isArchived => status == HomePromoStatus.archived;
  bool get isDemo => origin == ContentOrigin.demo;

  static HomePromoItem? tryParse(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final status = parseHomePromoStatus(json['status']);
    final origin = ContentOrigin.tryParse(json['origin']);
    if (status == null || origin == null) return null;

    final payloadRaw = json['payload'];
    if (payloadRaw is! Map) return null;
    final payload = HomePromoPayload.tryParse(
      Map<String, dynamic>.from(payloadRaw),
    );
    if (payload == null) return null;

    final title = (json['title'] ?? payload.title).toString();
    final rowVersion = _homePromoAsInt(json['row_version']) ?? 1;
    final priority = _homePromoAsInt(json['priority']) ?? 0;
    var sortOrder = 0;
    final placements = json['placements'];
    if (placements is List) {
      for (final p in placements.whereType<Map>()) {
        if (p['placement']?.toString() == 'home_promo') {
          sortOrder = _homePromoAsInt(p['sort_order']) ?? 0;
          break;
        }
      }
    }

    final legacyKeyRaw = json['legacy_key'] ?? json['legacyKey'];
    final legacyKey = legacyKeyRaw?.toString().trim();

    return HomePromoItem(
      id: id,
      status: status,
      origin: origin,
      title: title,
      payload: payload,
      rowVersion: rowVersion,
      priority: priority,
      sortOrder: sortOrder,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      templateKey:
          (json['template_key'] ?? json['templateKey'] ?? 'home_promo_v1')
              .toString(),
      schemaVersion: _homePromoAsInt(json['schema_version']) ?? 1,
      versionNumber: _homePromoAsInt(json['version_number']) ?? 1,
      isHidden: json['is_hidden'] == true,
      legacyKey: legacyKey == null || legacyKey.isEmpty ? null : legacyKey,
      startsAt: _homePromoAsDate(json['starts_at']),
      endsAt: _homePromoAsDate(json['ends_at']),
      audienceGroupIds: _asIdList(json['audience_group_ids']),
      audienceUserIds: _asIdList(json['audience_user_ids']),
    );
  }

  HomePromoItem copyWith({
    String? id,
    HomePromoStatus? status,
    ContentOrigin? origin,
    String? title,
    HomePromoPayload? payload,
    int? rowVersion,
    int? priority,
    int? sortOrder,
    String? audienceMode,
    String? templateKey,
    int? schemaVersion,
    int? versionNumber,
    bool? isHidden,
    String? legacyKey,
    bool clearLegacyKey = false,
    DateTime? startsAt,
    DateTime? endsAt,
    List<String>? audienceGroupIds,
    List<String>? audienceUserIds,
    bool clearStartsAt = false,
    bool clearEndsAt = false,
  }) {
    return HomePromoItem(
      id: id ?? this.id,
      status: status ?? this.status,
      origin: origin ?? this.origin,
      title: title ?? this.title,
      payload: payload ?? this.payload,
      rowVersion: rowVersion ?? this.rowVersion,
      priority: priority ?? this.priority,
      sortOrder: sortOrder ?? this.sortOrder,
      audienceMode: audienceMode ?? this.audienceMode,
      templateKey: templateKey ?? this.templateKey,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      versionNumber: versionNumber ?? this.versionNumber,
      isHidden: isHidden ?? this.isHidden,
      legacyKey: clearLegacyKey ? null : (legacyKey ?? this.legacyKey),
      startsAt: clearStartsAt ? null : (startsAt ?? this.startsAt),
      endsAt: clearEndsAt ? null : (endsAt ?? this.endsAt),
      audienceGroupIds: audienceGroupIds ?? this.audienceGroupIds,
      audienceUserIds: audienceUserIds ?? this.audienceUserIds,
    );
  }

  static List<String> _asIdList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
