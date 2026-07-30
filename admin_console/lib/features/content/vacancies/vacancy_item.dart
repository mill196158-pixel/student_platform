import 'package:student_ui/student_ui.dart';

import '../shared/content_working_draft.dart';

enum VacancyStatus {
  draft,
  submitted,
  inModeration,
  approved,
  published,
  expired,
  archived,
  rejected;

  static VacancyStatus? tryParse(Object? raw) {
    switch (raw?.toString()) {
      case 'draft':
        return VacancyStatus.draft;
      case 'submitted':
        return VacancyStatus.submitted;
      case 'in_moderation':
        return VacancyStatus.inModeration;
      case 'approved':
        return VacancyStatus.approved;
      case 'published':
        return VacancyStatus.published;
      case 'expired':
        return VacancyStatus.expired;
      case 'archived':
        return VacancyStatus.archived;
      case 'rejected':
        return VacancyStatus.rejected;
      default:
        return null;
    }
  }
}

String vacancyStatusWire(VacancyStatus status) {
  switch (status) {
    case VacancyStatus.draft:
      return 'draft';
    case VacancyStatus.submitted:
      return 'submitted';
    case VacancyStatus.inModeration:
      return 'in_moderation';
    case VacancyStatus.approved:
      return 'approved';
    case VacancyStatus.published:
      return 'published';
    case VacancyStatus.expired:
      return 'expired';
    case VacancyStatus.archived:
      return 'archived';
    case VacancyStatus.rejected:
      return 'rejected';
  }
}

class VacancyItem {
  const VacancyItem({
    required this.id,
    required this.status,
    required this.origin,
    required this.title,
    required this.companyName,
    required this.summary,
    required this.description,
    required this.rowVersion,
    required this.priority,
    required this.audienceMode,
    this.employmentType,
    this.workFormat,
    this.location,
    this.salaryText,
    this.externalUrl,
    this.contacts = const {},
    this.startsAt,
    this.endsAt,
    this.expiresAt,
    this.isHidden = false,
    this.rejectionReason,
    this.openReportCount = 0,
    this.audienceGroupIds = const [],
    this.audienceUserIds = const [],
    this.assetIds = const [],
    this.legacyKey,
    this.hasWorkingDraft = false,
    this.workingDraftRowVersion,
  });

  final String id;
  final VacancyStatus status;
  final ContentOrigin origin;
  final String title;
  final String companyName;
  final String summary;
  final String description;
  final int rowVersion;
  final int priority;
  final String audienceMode;
  final VacancyEmploymentType? employmentType;
  final VacancyWorkFormat? workFormat;
  final String? location;
  final String? salaryText;
  final String? externalUrl;
  final Map<String, dynamic> contacts;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final DateTime? expiresAt;
  final bool isHidden;
  final String? rejectionReason;
  final int openReportCount;
  final List<String> audienceGroupIds;
  final List<String> audienceUserIds;
  final List<String> assetIds;

  /// Stable Stage 14.1 bootstrap identity, retained after demo promotion.
  final String? legacyKey;

  /// True when a server/local working draft exists for this published item.
  final bool hasWorkingDraft;

  /// Present on begin/save responses; used for optimistic concurrency.
  final int? workingDraftRowVersion;

  bool get isPublished => status == VacancyStatus.published;

  VacancyCardPayload get previewPayload {
    final split = splitVacancyDescription(description);
    return VacancyCardPayload(
      title: title,
      companyName: companyName,
      summary: summary.isNotEmpty ? summary : description,
      descriptionFull: split.body.isNotEmpty ? split.body : description,
      requirementsText: split.requirements,
      employmentType: employmentType,
      workFormat: workFormat,
      location: location,
      salaryText: salaryText,
      externalUrl: externalUrl,
    );
  }

  static VacancyItem? tryParse(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    final status = VacancyStatus.tryParse(json['status']);
    final origin = ContentOrigin.tryParse(json['origin']);
    if (status == null || origin == null) return null;

    final title = json['title']?.toString().trim();
    if (title == null || title.isEmpty) return null;

    return VacancyItem(
      id: id,
      status: status,
      origin: origin,
      title: title,
      companyName: (json['company_name'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      rowVersion: _asInt(json['row_version']) ?? 1,
      priority: _asInt(json['priority']) ?? 0,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      employmentType: VacancyEmploymentType.tryParse(json['employment_type']),
      workFormat: VacancyWorkFormat.tryParse(json['work_format']),
      location: _nullableString(json['location']),
      salaryText: _nullableString(json['salary_text']),
      externalUrl: _nullableString(json['external_url']),
      contacts: _asContacts(json['contacts']),
      startsAt: _asDate(json['starts_at']),
      endsAt: _asDate(json['ends_at']),
      expiresAt: _asDate(json['expires_at']),
      isHidden: json['is_hidden'] == true,
      rejectionReason: _nullableString(json['rejection_reason']),
      openReportCount: _asInt(json['open_report_count']) ?? 0,
      audienceGroupIds: _asIdList(json['audience_group_ids']),
      audienceUserIds: _asIdList(json['audience_user_ids']),
      assetIds: _asIdList(json['asset_ids']),
      legacyKey: _nullableString(json['legacy_key']),
      hasWorkingDraft: parseHasWorkingDraft(json),
      workingDraftRowVersion: parseWorkingDraftRowVersion(
        parseWorkingDraftMap(json),
      ),
    );
  }

  static VacancyItem? tryParseWithWorkingDraftOverlay(
    Map<String, dynamic> json,
  ) {
    final base = tryParse(json);
    if (base == null) return null;
    final draft = parseWorkingDraftMap(json);
    if (draft == null) {
      return base.copyWith(hasWorkingDraft: parseHasWorkingDraft(json));
    }
    return base.copyWith(
      title: (draft['title'] ?? base.title).toString(),
      companyName: (draft['company_name'] ?? base.companyName).toString(),
      summary: (draft['summary'] ?? base.summary).toString(),
      description: (draft['description'] ?? base.description).toString(),
      priority: _asInt(draft['priority']) ?? base.priority,
      audienceMode: (draft['audience_mode'] ?? base.audienceMode).toString(),
      employmentType: draft.containsKey('employment_type')
          ? VacancyEmploymentType.tryParse(draft['employment_type'])
          : base.employmentType,
      workFormat: draft.containsKey('work_format')
          ? VacancyWorkFormat.tryParse(draft['work_format'])
          : base.workFormat,
      location: draft.containsKey('location')
          ? _nullableString(draft['location'])
          : base.location,
      salaryText: draft.containsKey('salary_text')
          ? _nullableString(draft['salary_text'])
          : base.salaryText,
      externalUrl: draft.containsKey('external_url')
          ? _nullableString(draft['external_url'])
          : base.externalUrl,
      contacts: draft['contacts'] is Map
          ? Map<String, dynamic>.from(draft['contacts'] as Map)
          : base.contacts,
      startsAt: draft.containsKey('starts_at')
          ? _asDate(draft['starts_at'])
          : base.startsAt,
      endsAt: draft.containsKey('ends_at')
          ? _asDate(draft['ends_at'])
          : base.endsAt,
      expiresAt: draft.containsKey('expires_at')
          ? _asDate(draft['expires_at'])
          : base.expiresAt,
      isHidden: draft['is_hidden'] is bool
          ? draft['is_hidden'] as bool
          : base.isHidden,
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

  VacancyItem copyWith({
    VacancyStatus? status,
    ContentOrigin? origin,
    String? title,
    String? companyName,
    String? summary,
    String? description,
    int? rowVersion,
    int? priority,
    String? audienceMode,
    VacancyEmploymentType? employmentType,
    VacancyWorkFormat? workFormat,
    String? location,
    String? salaryText,
    String? externalUrl,
    Map<String, dynamic>? contacts,
    DateTime? startsAt,
    DateTime? endsAt,
    DateTime? expiresAt,
    bool? isHidden,
    String? rejectionReason,
    int? openReportCount,
    List<String>? audienceGroupIds,
    List<String>? audienceUserIds,
    List<String>? assetIds,
    String? legacyKey,
    bool clearEmploymentType = false,
    bool clearWorkFormat = false,
    bool clearLocation = false,
    bool clearSalaryText = false,
    bool clearExternalUrl = false,
    bool clearStartsAt = false,
    bool clearEndsAt = false,
    bool clearExpiresAt = false,
    bool? hasWorkingDraft,
    int? workingDraftRowVersion,
    bool clearWorkingDraftRowVersion = false,
  }) {
    return VacancyItem(
      id: id,
      status: status ?? this.status,
      origin: origin ?? this.origin,
      title: title ?? this.title,
      companyName: companyName ?? this.companyName,
      summary: summary ?? this.summary,
      description: description ?? this.description,
      rowVersion: rowVersion ?? this.rowVersion,
      priority: priority ?? this.priority,
      audienceMode: audienceMode ?? this.audienceMode,
      employmentType: clearEmploymentType
          ? null
          : (employmentType ?? this.employmentType),
      workFormat: clearWorkFormat ? null : (workFormat ?? this.workFormat),
      location: clearLocation ? null : (location ?? this.location),
      salaryText: clearSalaryText ? null : (salaryText ?? this.salaryText),
      externalUrl: clearExternalUrl ? null : (externalUrl ?? this.externalUrl),
      contacts: contacts ?? this.contacts,
      startsAt: clearStartsAt ? null : (startsAt ?? this.startsAt),
      endsAt: clearEndsAt ? null : (endsAt ?? this.endsAt),
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      isHidden: isHidden ?? this.isHidden,
      rejectionReason: rejectionReason ?? this.rejectionReason,
      openReportCount: openReportCount ?? this.openReportCount,
      audienceGroupIds: audienceGroupIds ?? this.audienceGroupIds,
      audienceUserIds: audienceUserIds ?? this.audienceUserIds,
      assetIds: assetIds ?? this.assetIds,
      legacyKey: legacyKey ?? this.legacyKey,
      hasWorkingDraft: hasWorkingDraft ?? this.hasWorkingDraft,
      workingDraftRowVersion: clearWorkingDraftRowVersion
          ? null
          : (workingDraftRowVersion ?? this.workingDraftRowVersion),
    );
  }

  Map<String, dynamic> toWorkingDraftPatch() {
    // Draft media visibility is server-owned via vacancy_assets.working_draft_id.
    // Do not send all assetIds as draft_asset_ids (would hide published attachments).
    return {
      ...toDraftPatch(),
      'is_hidden': isHidden,
      'audience_mode': audienceMode,
      'audience_group_ids': audienceGroupIds,
      'audience_user_ids': audienceUserIds,
    };
  }

  /// Marker separating main description from requirements in [description].
  static String get requirementsMarker => vacancyRequirementsMarker;

  /// Requirements text extracted from [description] (no separate DB column).
  String get requirementsText {
    final idx = description.indexOf(requirementsMarker);
    if (idx < 0) return '';
    return description.substring(idx + requirementsMarker.length).trim();
  }

  /// Main description body without the requirements section.
  String get descriptionBody {
    final idx = description.indexOf(requirementsMarker);
    if (idx < 0) return description;
    return description.substring(0, idx).trim();
  }

  /// Builds full description wire value from body + optional requirements.
  static String buildDescription(String body, String requirements) {
    final trimmedBody = body.trim();
    final trimmedReq = requirements.trim();
    if (trimmedReq.isEmpty) return trimmedBody;
    if (trimmedBody.isEmpty) {
      return '${requirementsMarker.trim()}$trimmedReq';
    }
    return '$trimmedBody$requirementsMarker$trimmedReq';
  }

  Map<String, dynamic> toDraftPatch() {
    return {
      'title': title,
      'company_name': companyName,
      'summary': summary,
      'description': description,
      if (employmentType != null) 'employment_type': employmentType!.wireValue,
      if (workFormat != null) 'work_format': workFormat!.wireValue,
      if (location != null && location!.isNotEmpty) 'location': location,
      if (salaryText != null && salaryText!.isNotEmpty)
        'salary_text': salaryText,
      if (externalUrl != null && externalUrl!.isNotEmpty)
        'external_url': externalUrl,
      if (contacts.isNotEmpty) 'contacts': contacts,
      'priority': priority,
      if (startsAt != null) 'starts_at': startsAt!.toUtc().toIso8601String(),
      if (endsAt != null) 'ends_at': endsAt!.toUtc().toIso8601String(),
      if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    };
  }

  /// Patch for mobile `submit_vacancy(p_patch)` — content fields only.
  Map<String, dynamic> toSubmitPatch() {
    return {
      'title': title,
      'company_name': companyName,
      'summary': summary,
      'description': description,
      if (employmentType != null) 'employment_type': employmentType!.wireValue,
      if (workFormat != null) 'work_format': workFormat!.wireValue,
      if (location != null && location!.isNotEmpty) 'location': location,
      if (salaryText != null && salaryText!.isNotEmpty)
        'salary_text': salaryText,
      if (externalUrl != null && externalUrl!.isNotEmpty)
        'external_url': externalUrl,
      if (contacts.isNotEmpty) 'contacts': contacts,
    };
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

  static String? _nullableString(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    return text.isEmpty ? null : text;
  }

  static Map<String, dynamic> _asContacts(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const {};
  }

  static List<String> _asIdList(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
