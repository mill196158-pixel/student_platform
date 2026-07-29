import 'package:student_ui/student_ui.dart';

enum ProfileFeedStatus { draft, published, archived }

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
    this.startsAt,
    this.endsAt,
    this.audienceGroupIds = const [],
    this.audienceUserIds = const [],
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
  final DateTime? startsAt;
  final DateTime? endsAt;
  final List<String> audienceGroupIds;
  final List<String> audienceUserIds;

  static ProfileFeedItem? tryParse(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final status = parseProfileFeedStatus(json['status']);
    final origin = ContentOrigin.tryParse(json['origin']);
    if (status == null || origin == null) return null;

    final templateKey =
        (json['template_key'] ?? json['templateKey'])?.toString();
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
      startsAt: _asDate(json['starts_at']),
      endsAt: _asDate(json['ends_at']),
      audienceGroupIds: _asIdList(json['audience_group_ids']),
      audienceUserIds: _asIdList(json['audience_user_ids']),
    );
  }

  ProfileFeedItem copyWith({
    ProfileFeedStatus? status,
    ContentOrigin? origin,
    String? title,
    ProfileFeedPayload? payload,
    int? rowVersion,
    int? priority,
    int? sortOrder,
    String? audienceMode,
    DateTime? startsAt,
    DateTime? endsAt,
    List<String>? audienceGroupIds,
    List<String>? audienceUserIds,
    bool clearStartsAt = false,
    bool clearEndsAt = false,
  }) {
    return ProfileFeedItem(
      id: id,
      status: status ?? this.status,
      origin: origin ?? this.origin,
      title: title ?? this.title,
      payload: payload ?? this.payload,
      rowVersion: rowVersion ?? this.rowVersion,
      priority: priority ?? this.priority,
      sortOrder: sortOrder ?? this.sortOrder,
      audienceMode: audienceMode ?? this.audienceMode,
      startsAt: clearStartsAt ? null : (startsAt ?? this.startsAt),
      endsAt: clearEndsAt ? null : (endsAt ?? this.endsAt),
      audienceGroupIds: audienceGroupIds ?? this.audienceGroupIds,
      audienceUserIds: audienceUserIds ?? this.audienceUserIds,
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
