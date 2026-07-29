import 'package:flutter/material.dart';

/// Wire values from `public.entity_reviews.entity_type`.
enum ReviewEntityType {
  teacher,
  subject;

  static ReviewEntityType? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'teacher':
        return ReviewEntityType.teacher;
      case 'subject':
        return ReviewEntityType.subject;
      default:
        return null;
    }
  }

  String get wireValue {
    switch (this) {
      case ReviewEntityType.teacher:
        return 'teacher';
      case ReviewEntityType.subject:
        return 'subject';
    }
  }

  String get labelRu {
    switch (this) {
      case ReviewEntityType.teacher:
        return 'Преподаватель';
      case ReviewEntityType.subject:
        return 'Предмет';
    }
  }
}

/// Stage 18 moderation state on `entity_reviews.moderation_status`.
enum ReviewModerationStatus {
  draft,
  pending,
  approved,
  rejected;

  static ReviewModerationStatus? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'draft':
        return ReviewModerationStatus.draft;
      case 'pending':
        return ReviewModerationStatus.pending;
      case 'approved':
        return ReviewModerationStatus.approved;
      case 'rejected':
        return ReviewModerationStatus.rejected;
      default:
        return null;
    }
  }

  String get wireValue {
    switch (this) {
      case ReviewModerationStatus.draft:
        return 'draft';
      case ReviewModerationStatus.pending:
        return 'pending';
      case ReviewModerationStatus.approved:
        return 'approved';
      case ReviewModerationStatus.rejected:
        return 'rejected';
    }
  }

  String get labelRu {
    switch (this) {
      case ReviewModerationStatus.draft:
        return 'Черновик';
      case ReviewModerationStatus.pending:
        return 'На модерации';
      case ReviewModerationStatus.approved:
        return 'Одобрен';
      case ReviewModerationStatus.rejected:
        return 'Отклонён';
    }
  }
}

/// Public aggregate from `get_entity_review_summary` (no author disclosure).
@immutable
class EntityReviewSummary {
  const EntityReviewSummary({
    required this.entityType,
    required this.entityId,
    this.activeCount = 0,
    this.tagAverages = const {},
    this.textEnabled = false,
    this.structuredEnabled = false,
  });

  final ReviewEntityType entityType;
  final String entityId;
  final int activeCount;
  final Map<String, double> tagAverages;
  final bool textEnabled;
  final bool structuredEnabled;

  static EntityReviewSummary? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final entityType = ReviewEntityType.tryParse(json['entity_type']);
      final entityId = _readString(json, const ['entity_id', 'entityId']);
      if (entityType == null || entityId == null) return null;

      final activeCount = _readInt(json, const ['active_count', 'activeCount']) ?? 0;
      final tagAverages = _readTagAverages(json['tag_averages']);

      return EntityReviewSummary(
        entityType: entityType,
        entityId: entityId,
        activeCount: activeCount,
        tagAverages: tagAverages,
        textEnabled: json['text_enabled'] == true,
        structuredEnabled: json['structured_enabled'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  bool get hasReviews => activeCount > 0;
}

/// Reason codes from `student_points_ledger.reason_code`.
enum PointsReasonCode {
  reviewApproved,
  reviewCreditRevoked,
  manualAdjustment;

  static PointsReasonCode? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'review_approved':
        return PointsReasonCode.reviewApproved;
      case 'review_credit_revoked':
        return PointsReasonCode.reviewCreditRevoked;
      case 'manual_adjustment':
        return PointsReasonCode.manualAdjustment;
      default:
        return null;
    }
  }

  String get labelRu {
    switch (this) {
      case PointsReasonCode.reviewApproved:
        return 'Одобренный отзыв';
      case PointsReasonCode.reviewCreditRevoked:
        return 'Списание за нарушение';
      case PointsReasonCode.manualAdjustment:
        return 'Корректировка';
    }
  }
}

/// One ledger row from `get_my_points_summary.entries`.
@immutable
class StudentPointsEntry {
  const StudentPointsEntry({
    required this.delta,
    required this.reasonCode,
    this.createdAt,
  });

  final int delta;
  final PointsReasonCode reasonCode;
  final DateTime? createdAt;

  static StudentPointsEntry? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final delta = _readInt(json, const ['delta']);
      final reason = PointsReasonCode.tryParse(json['reason_code']);
      if (delta == null || reason == null) return null;
      return StudentPointsEntry(
        delta: delta,
        reasonCode: reason,
        createdAt: _readDate(json['created_at']),
      );
    } catch (_) {
      return null;
    }
  }

  String get signedLabel => delta > 0 ? '+$delta' : '$delta';
}

/// Mobile points payload from `get_my_points_summary`.
@immutable
class StudentPointsSummary {
  const StudentPointsSummary({
    required this.userId,
    this.balance = 0,
    this.entries = const [],
  });

  final String userId;
  final int balance;
  final List<StudentPointsEntry> entries;

  static const StudentPointsSummary demo = StudentPointsSummary(
    userId: 'demo-user',
    balance: 2,
    entries: [
      StudentPointsEntry(
        delta: 1,
        reasonCode: PointsReasonCode.reviewApproved,
      ),
      StudentPointsEntry(
        delta: 1,
        reasonCode: PointsReasonCode.reviewApproved,
      ),
    ],
  );

  static StudentPointsSummary? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final userId = _readString(json, const ['user_id', 'userId']);
      if (userId == null) return null;
      final balance = _readInt(json, const ['balance']) ?? 0;
      final entries = <StudentPointsEntry>[];
      final rawEntries = json['entries'];
      if (rawEntries is List) {
        for (final row in rawEntries) {
          if (row is! Map) continue;
          final entry = StudentPointsEntry.tryParse(
            Map<String, dynamic>.from(row),
          );
          if (entry != null) entries.add(entry);
        }
      }
      return StudentPointsSummary(
        userId: userId,
        balance: balance,
        entries: entries,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Domains returned by `admin_list_unified_moderation_queue`.
enum ModerationQueueDomain {
  review,
  reviewReport,
  vacancy,
  vacancyReport,
  contentCorrection;

  static ModerationQueueDomain? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'review':
        return ModerationQueueDomain.review;
      case 'review_report':
        return ModerationQueueDomain.reviewReport;
      case 'vacancy':
        return ModerationQueueDomain.vacancy;
      case 'vacancy_report':
        return ModerationQueueDomain.vacancyReport;
      case 'content_correction':
        return ModerationQueueDomain.contentCorrection;
      default:
        return null;
    }
  }

  String get wireValue {
    switch (this) {
      case ModerationQueueDomain.review:
        return 'review';
      case ModerationQueueDomain.reviewReport:
        return 'review_report';
      case ModerationQueueDomain.vacancy:
        return 'vacancy';
      case ModerationQueueDomain.vacancyReport:
        return 'vacancy_report';
      case ModerationQueueDomain.contentCorrection:
        return 'content_correction';
    }
  }

  String get labelRu {
    switch (this) {
      case ModerationQueueDomain.review:
        return 'Отзыв';
      case ModerationQueueDomain.reviewReport:
        return 'Жалоба на отзыв';
      case ModerationQueueDomain.vacancy:
        return 'Вакансия';
      case ModerationQueueDomain.vacancyReport:
        return 'Жалоба на вакансию';
      case ModerationQueueDomain.contentCorrection:
        return 'Исправление контента';
    }
  }
}

/// One row from `admin_list_unified_moderation_queue`.
@immutable
class UnifiedModerationQueueItem {
  const UnifiedModerationQueueItem({
    required this.domain,
    required this.entityId,
    required this.title,
    required this.status,
    this.parentId,
    this.detail,
    this.reasonCode,
    this.openReports = 0,
    this.rowVersion,
    this.createdAt,
    this.updatedAt,
    this.authorUserId,
    this.authorLabel,
    this.assigneeUserId,
    this.priority,
  });

  final ModerationQueueDomain domain;
  final String entityId;
  final String? parentId;
  final String title;
  final String? detail;
  final String status;
  final String? reasonCode;
  final int openReports;
  final int? rowVersion;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  /// Moderator-only; never shown on public/mobile surfaces.
  final String? authorUserId;
  final String? authorLabel;
  final String? assigneeUserId;
  final int? priority;

  static UnifiedModerationQueueItem? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final domain = ModerationQueueDomain.tryParse(json['domain']);
      final entityId = _readString(json, const ['entity_id', 'entityId']);
      final title = _readString(json, const ['title']) ?? '';
      final status = _readString(json, const ['status']) ?? 'open';
      if (domain == null || entityId == null) return null;

      return UnifiedModerationQueueItem(
        domain: domain,
        entityId: entityId,
        parentId: _readString(json, const ['parent_id', 'parentId']),
        title: title,
        detail: _readString(json, const ['detail']),
        status: status,
        reasonCode: _readString(json, const ['reason_code', 'reasonCode']),
        openReports: _readInt(json, const ['open_reports', 'openReports']) ?? 0,
        rowVersion: _readInt(json, const ['row_version', 'rowVersion']),
        createdAt: _readDate(json['created_at']),
        updatedAt: _readDate(json['updated_at']),
        authorUserId: _readString(json, const ['author_user_id', 'authorUserId']),
        authorLabel: _readString(json, const ['author_label', 'authorLabel']),
        assigneeUserId:
            _readString(json, const ['assignee_user_id', 'assigneeUserId']),
        priority: _readInt(json, const ['priority']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Stage 13.6 structured tag codes per entity type.
const List<String> teacherReviewTagCodes = [
  'clarity',
  'fairness',
  'availability',
];

const List<String> subjectReviewTagCodes = [
  'usefulness',
  'workload',
  'organization',
];

const Map<String, String> reviewTagLabelsRu = {
  'clarity': 'Понятность',
  'fairness': 'Справедливость',
  'availability': 'Доступность',
  'usefulness': 'Полезность',
  'workload': 'Нагрузка',
  'organization': 'Организация',
};

List<String> reviewTagCodesFor(ReviewEntityType type) {
  switch (type) {
    case ReviewEntityType.teacher:
      return teacherReviewTagCodes;
    case ReviewEntityType.subject:
      return subjectReviewTagCodes;
  }
}

/// One row from `get_my_entity_reviews`.
@immutable
class MyEntityReviewItem {
  const MyEntityReviewItem({
    required this.reviewId,
    required this.entityType,
    required this.entityId,
    required this.entityLabel,
    this.tagScores = const {},
    this.bodyPreview,
    this.moderationStatus,
    this.moderationReason,
    this.updatedAt,
  });

  final String reviewId;
  final ReviewEntityType entityType;
  final String entityId;
  final String entityLabel;
  final Map<String, int> tagScores;
  final String? bodyPreview;
  final ReviewModerationStatus? moderationStatus;
  /// Author-visible moderator note (reject / request_clarification).
  final String? moderationReason;
  final DateTime? updatedAt;

  StudentReviewCardPayload toCardPayload() => StudentReviewCardPayload(
        entityType: entityType,
        entityLabel: entityLabel,
        tagScores: tagScores,
        bodyPreview: bodyPreview,
        moderationStatus: moderationStatus,
        moderationReason: moderationReason,
      );

  static MyEntityReviewItem? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final reviewId = _readString(json, const ['review_id', 'reviewId']);
      final entityType = ReviewEntityType.tryParse(json['entity_type']);
      final entityId = _readString(json, const ['entity_id', 'entityId']);
      final entityLabel = _readString(json, const ['entity_label', 'entityLabel']);
      if (reviewId == null ||
          entityType == null ||
          entityId == null ||
          entityLabel == null) {
        return null;
      }
      final tagScores = <String, int>{};
      final rawScores = json['tag_scores'];
      if (rawScores is Map) {
        for (final entry in rawScores.entries) {
          final value = entry.value;
          if (value is num) tagScores['${entry.key}'] = value.toInt();
        }
      }
      return MyEntityReviewItem(
        reviewId: reviewId,
        entityType: entityType,
        entityId: entityId,
        entityLabel: entityLabel,
        tagScores: tagScores,
        bodyPreview: _readString(json, const ['body_text', 'bodyText']),
        moderationStatus:
            ReviewModerationStatus.tryParse(json['moderation_status']),
        moderationReason: _readString(
          json,
          const ['moderation_reason', 'moderationReason'],
        ),
        updatedAt: _readDate(json['updated_at']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Mobile card payload for a student's own review (submit / status UI).
@immutable
class StudentReviewCardPayload {
  const StudentReviewCardPayload({
    required this.entityType,
    required this.entityLabel,
    this.tagScores = const {},
    this.bodyPreview,
    this.moderationStatus,
    this.moderationReason,
    this.openReports = 0,
  });

  final ReviewEntityType entityType;
  final String entityLabel;
  final Map<String, int> tagScores;
  final String? bodyPreview;
  final ReviewModerationStatus? moderationStatus;
  final String? moderationReason;
  final int openReports;

  static const StudentReviewCardPayload demoTeacher = StudentReviewCardPayload(
    entityType: ReviewEntityType.teacher,
    entityLabel: 'Иванова А.А.',
    tagScores: {'clarity': 5, 'fairness': 4, 'availability': 4},
    moderationStatus: ReviewModerationStatus.approved,
  );

  static const StudentReviewCardPayload demoPending = StudentReviewCardPayload(
    entityType: ReviewEntityType.subject,
    entityLabel: 'Математический анализ',
    tagScores: {'usefulness': 4, 'workload': 3, 'organization': 4},
    bodyPreview: 'Курс требовательный, но материал подаётся структурно.',
    moderationStatus: ReviewModerationStatus.pending,
  );

  String get moderationLabel => moderationStatus?.labelRu ?? '—';

  String get tagSummary {
    if (tagScores.isEmpty) return 'Без оценок';
    return tagScores.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(' · ');
  }
}

String? _readString(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }
  return null;
}

int? _readInt(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
  return null;
}

DateTime? _readDate(Object? raw) {
  if (raw == null) return null;
  return DateTime.tryParse(raw.toString());
}

Map<String, double> _readTagAverages(Object? raw) {
  if (raw is! Map) return const {};
  final out = <String, double>{};
  for (final entry in raw.entries) {
    final value = entry.value;
    if (value is num) {
      out['${entry.key}'] = value.toDouble();
    }
  }
  return out;
}
