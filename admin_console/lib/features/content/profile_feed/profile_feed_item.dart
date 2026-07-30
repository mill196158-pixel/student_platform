import 'package:student_ui/student_ui.dart';

import '../shared/content_working_draft.dart';

enum ProfileFeedStatus { draft, published, archived }

extension ProfileFeedStatusLabels on ProfileFeedStatus {
  String get russianLabel => switch (this) {
    ProfileFeedStatus.draft => 'Черновик',
    ProfileFeedStatus.published => 'Опубликован',
    ProfileFeedStatus.archived => 'В архиве',
  };

  bool get isDraft => this == ProfileFeedStatus.draft;
  bool get isPublished => this == ProfileFeedStatus.published;
  bool get isArchived => this == ProfileFeedStatus.archived;
}

ProfileFeedStatus? parseProfileFeedStatus(Object? raw) {
  switch (raw?.toString()) {
    case 'draft':
      return ProfileFeedStatus.draft;
    case 'published':
      return ProfileFeedStatus.published;
    case 'archived':
      return ProfileFeedStatus.archived;
    default:
      return null;
  }
}

String profileFeedStatusWire(ProfileFeedStatus status) {
  switch (status) {
    case ProfileFeedStatus.draft:
      return 'draft';
    case ProfileFeedStatus.published:
      return 'published';
    case ProfileFeedStatus.archived:
      return 'archived';
  }
}

class ProfileFeedVersionInfo {
  const ProfileFeedVersionInfo({
    required this.versionNumber,
    this.createdAt,
    this.title = '',
    this.status,
  });

  final int versionNumber;
  final DateTime? createdAt;
  final String title;
  final ProfileFeedStatus? status;

  factory ProfileFeedVersionInfo.fromJson(Map<String, dynamic> json) {
    final snapshot = json['snapshot'];
    String title = '';
    ProfileFeedStatus? status;
    if (snapshot is Map) {
      title = (snapshot['title'] ?? '').toString();
      status = parseProfileFeedStatus(snapshot['status']);
    }
    return ProfileFeedVersionInfo(
      versionNumber: ProfileFeedItem._asInt(json['version_number']) ?? 0,
      createdAt: ProfileFeedItem._asDate(json['created_at']),
      title: title,
      status: status,
    );
  }
}

class ProfileFeedDeleteResult {
  const ProfileFeedDeleteResult({
    required this.id,
    this.legacyKey,
    this.queuedMedia = 0,
  });

  final String id;
  final String? legacyKey;
  final int queuedMedia;

  factory ProfileFeedDeleteResult.fromJson(Map<String, dynamic> json) {
    return ProfileFeedDeleteResult(
      id: (json['id'] ?? '').toString(),
      legacyKey: json['legacy_key']?.toString(),
      queuedMedia: ProfileFeedItem._asInt(json['queued_media']) ?? 0,
    );
  }
}

extension ProfileFeedItemStatus on ProfileFeedItem {
  bool get isDraft => status.isDraft;
  bool get isPublished => status.isPublished;
  bool get isArchived => status.isArchived;
}

class ProfileFeedItem {
  const ProfileFeedItem({
    required this.id,
    required this.status,
    required this.origin,
    required this.title,
    required this.payload,
    required this.rowVersion,
    required this.priority,
    required this.sortOrder,
    required this.audienceMode,
    this.legacyKey,
    this.versionNumber = 1,
    this.startsAt,
    this.endsAt,
    this.audienceGroupIds = const [],
    this.audienceUserIds = const [],
    this.hasWorkingDraft = false,
    this.workingDraftRowVersion,
  });

  final String id;
  final ProfileFeedStatus status;
  final ContentOrigin origin;
  final String title;
  final ProfileFeedPayload payload;
  final int rowVersion;
  final int priority;
  final int sortOrder;
  final String audienceMode;
  final String? legacyKey;
  final int versionNumber;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final List<String> audienceGroupIds;
  final List<String> audienceUserIds;

  /// True when a server/local working draft exists for this published item.
  final bool hasWorkingDraft;

  /// Present on begin/save responses; used for optimistic concurrency.
  final int? workingDraftRowVersion;

  static ProfileFeedItem? tryParse(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final status = parseProfileFeedStatus(json['status']);
    final origin = ContentOrigin.tryParse(json['origin']);
    if (status == null || origin == null) return null;

    final templateKey = (json['template_key'] ?? json['templateKey'])
        ?.toString();
    if (templateKey != null &&
        templateKey.isNotEmpty &&
        templateKey != 'profile_feed_card_v1') {
      return null;
    }

    final payloadRaw = json['payload'];
    if (payloadRaw is! Map) return null;
    final payload = ProfileFeedPayload.tryParse(
      Map<String, dynamic>.from(payloadRaw),
    );
    if (payload == null) return null;

    final title = (json['title'] ?? payload.title).toString();
    final rowVersion = _asInt(json['row_version']) ?? 1;
    final priority = _asInt(json['priority']) ?? 0;
    var sortOrder = 0;
    final placements = json['placements'];
    if (placements is List) {
      for (final p in placements.whereType<Map>()) {
        if (p['placement']?.toString() == 'profile_feed') {
          sortOrder = _asInt(p['sort_order']) ?? 0;
          break;
        }
      }
    } else {
      sortOrder = _asInt(json['sort_order']) ?? 0;
    }

    return ProfileFeedItem(
      id: id,
      status: status,
      origin: origin,
      title: title,
      payload: payload,
      rowVersion: rowVersion,
      priority: priority,
      sortOrder: sortOrder,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      legacyKey: json['legacy_key']?.toString(),
      versionNumber: _asInt(json['version_number']) ?? 1,
      startsAt: _asDate(json['starts_at']),
      endsAt: _asDate(json['ends_at']),
      audienceGroupIds: _asIdList(json['audience_group_ids']),
      audienceUserIds: _asIdList(json['audience_user_ids']),
      hasWorkingDraft: parseHasWorkingDraft(json),
      workingDraftRowVersion: parseWorkingDraftRowVersion(
        parseWorkingDraftMap(json),
      ),
    );
  }

  static ProfileFeedItem? tryParseWithWorkingDraftOverlay(
    Map<String, dynamic> json,
  ) {
    final base = tryParse(json);
    if (base == null) return null;
    final draft = parseWorkingDraftMap(json);
    if (draft == null) {
      return base.copyWith(hasWorkingDraft: parseHasWorkingDraft(json));
    }
    final payloadRaw = draft['payload'];
    ProfileFeedPayload? payload;
    if (payloadRaw is Map) {
      payload = ProfileFeedPayload.tryParse(
        Map<String, dynamic>.from(payloadRaw),
      );
    }
    return base.copyWith(
      title: (draft['title'] ?? base.title).toString(),
      payload: payload ?? base.payload,
      priority: _asInt(draft['priority']) ?? base.priority,
      sortOrder: _asInt(draft['sort_order']) ?? base.sortOrder,
      audienceMode: (draft['audience_mode'] ?? base.audienceMode).toString(),
      startsAt: draft.containsKey('starts_at')
          ? _asDate(draft['starts_at'])
          : base.startsAt,
      endsAt: draft.containsKey('ends_at')
          ? _asDate(draft['ends_at'])
          : base.endsAt,
      clearStartsAt:
          draft.containsKey('starts_at') && draft['starts_at'] == null,
      clearEndsAt: draft.containsKey('ends_at') && draft['ends_at'] == null,
      audienceGroupIds: draft['audience_group_ids'] != null
          ? _asIdList(draft['audience_group_ids'])
          : base.audienceGroupIds,
      audienceUserIds: draft['audience_user_ids'] != null
          ? _asIdList(draft['audience_user_ids'])
          : base.audienceUserIds,
      hasWorkingDraft: true,
      workingDraftRowVersion: parseWorkingDraftRowVersion(draft),
    );
  }

  Map<String, dynamic> toWorkingDraftPatch({bool includeIsHidden = false}) {
    final imageAssetId = payload.imageAssetId?.trim();
    final iconAssetId = payload.iconAssetId?.trim();
    final assetIds = <String>{
      if (imageAssetId != null && imageAssetId.isNotEmpty) imageAssetId,
      if (iconAssetId != null && iconAssetId.isNotEmpty) iconAssetId,
    };
    return {
      'title': title,
      'payload': payload.toWireJson(),
      'target_schema_version': 2,
      'priority': priority,
      'starts_at': startsAt?.toUtc().toIso8601String(),
      'ends_at': endsAt?.toUtc().toIso8601String(),
      if (includeIsHidden) 'is_hidden': false,
      'audience_mode': audienceMode,
      'audience_group_ids': audienceGroupIds,
      'audience_user_ids': audienceUserIds,
      'sort_order': sortOrder,
      if (assetIds.isNotEmpty) 'draft_asset_ids': assetIds.toList(),
    };
  }

  ManagedProfileFeedCard toManagedCard({bool? showDemoBadge}) {
    return ManagedProfileFeedCard(
      id: id,
      origin: origin,
      sortOrder: sortOrder,
      priority: priority,
      payload: payload,
      showDemoBadge: showDemoBadge ?? origin == ContentOrigin.demo,
    );
  }

  ProfileFeedItem copyWith({
    String? id,
    ProfileFeedStatus? status,
    ContentOrigin? origin,
    String? title,
    ProfileFeedPayload? payload,
    int? rowVersion,
    int? priority,
    int? sortOrder,
    String? audienceMode,
    String? legacyKey,
    int? versionNumber,
    DateTime? startsAt,
    DateTime? endsAt,
    List<String>? audienceGroupIds,
    List<String>? audienceUserIds,
    bool clearStartsAt = false,
    bool clearEndsAt = false,
    bool clearLegacyKey = false,
    bool? hasWorkingDraft,
    int? workingDraftRowVersion,
    bool clearWorkingDraftRowVersion = false,
  }) {
    return ProfileFeedItem(
      id: id ?? this.id,
      status: status ?? this.status,
      origin: origin ?? this.origin,
      title: title ?? this.title,
      payload: payload ?? this.payload,
      rowVersion: rowVersion ?? this.rowVersion,
      priority: priority ?? this.priority,
      sortOrder: sortOrder ?? this.sortOrder,
      audienceMode: audienceMode ?? this.audienceMode,
      legacyKey: clearLegacyKey ? null : (legacyKey ?? this.legacyKey),
      versionNumber: versionNumber ?? this.versionNumber,
      startsAt: clearStartsAt ? null : (startsAt ?? this.startsAt),
      endsAt: clearEndsAt ? null : (endsAt ?? this.endsAt),
      audienceGroupIds: audienceGroupIds ?? this.audienceGroupIds,
      audienceUserIds: audienceUserIds ?? this.audienceUserIds,
      hasWorkingDraft: hasWorkingDraft ?? this.hasWorkingDraft,
      workingDraftRowVersion: clearWorkingDraftRowVersion
          ? null
          : (workingDraftRowVersion ?? this.workingDraftRowVersion),
    );
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '');
  }

  static DateTime? _asDate(Object? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString());
  }

  static List<String> _asIdList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
