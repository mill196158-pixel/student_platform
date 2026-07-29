import 'package:student_ui/student_ui.dart';

/// Legacy Stage 13.6 review queue row (`admin_list_moderation_queue`).
class LegacyReviewQueueItem {
  const LegacyReviewQueueItem({
    required this.reviewId,
    required this.entityType,
    required this.entityId,
    required this.status,
    this.bodyText,
    this.tagScores = const {},
    this.openReports = 0,
    this.hiddenReason,
  });

  final String reviewId;
  final ReviewEntityType entityType;
  final String entityId;
  final String status;
  final String? bodyText;
  final Map<String, dynamic> tagScores;
  final int openReports;
  final String? hiddenReason;

  factory LegacyReviewQueueItem.fromJson(Map<String, dynamic> json) {
    return LegacyReviewQueueItem(
      reviewId: '${json['review_id'] ?? json['reviewId'] ?? ''}',
      entityType:
          ReviewEntityType.tryParse(json['entity_type']) ??
          ReviewEntityType.teacher,
      entityId: '${json['entity_id'] ?? json['entityId'] ?? ''}',
      status: '${json['status'] ?? 'active'}',
      bodyText: json['body_text']?.toString(),
      tagScores: json['tag_scores'] is Map
          ? Map<String, dynamic>.from(json['tag_scores'] as Map)
          : const {},
      openReports: int.tryParse('${json['open_reports'] ?? 0}') ?? 0,
      hiddenReason: json['hidden_reason']?.toString(),
    );
  }
}

/// Content correction row (`admin_list_content_corrections`).
class ContentCorrectionQueueItem {
  const ContentCorrectionQueueItem({
    required this.id,
    required this.contentItemId,
    required this.contentTitle,
    required this.status,
    this.note,
    this.templateKey,
    this.resolutionNote,
  });

  final String id;
  final String contentItemId;
  final String contentTitle;
  final String status;
  final String? note;
  final String? templateKey;
  final String? resolutionNote;

  factory ContentCorrectionQueueItem.fromJson(Map<String, dynamic> json) {
    return ContentCorrectionQueueItem(
      id: '${json['id'] ?? ''}',
      contentItemId: '${json['content_item_id'] ?? json['contentItemId'] ?? ''}',
      contentTitle:
          '${json['content_title'] ?? json['contentTitle'] ?? 'Контент'}',
      status: '${json['status'] ?? 'open'}',
      note: json['note']?.toString(),
      templateKey: json['template_key']?.toString(),
      resolutionNote: json['resolution_note']?.toString(),
    );
  }
}

class ModerationRepositoryException implements Exception {
  const ModerationRepositoryException(
    this.message, {
    this.isForbidden = false,
  });

  final String message;
  final bool isForbidden;

  @override
  String toString() => message;
}

class ModerationHistoryEntry {
  const ModerationHistoryEntry({
    required this.action,
    this.reasonText,
    this.createdAt,
    this.fromStatus,
    this.toStatus,
  });

  final String action;
  final String? reasonText;
  final DateTime? createdAt;
  final String? fromStatus;
  final String? toStatus;

  factory ModerationHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ModerationHistoryEntry(
      action: '${json['action'] ?? ''}',
      reasonText: json['reason_text']?.toString(),
      createdAt: DateTime.tryParse('${json['created_at'] ?? ''}'),
      fromStatus: json['from_status']?.toString(),
      toStatus: json['to_status']?.toString(),
    );
  }
}

abstract class ModerationRepository {
  Future<List<LegacyReviewQueueItem>> listLegacyReviewQueue({
    String status = 'queue',
    int limit = 50,
  });

  Future<List<UnifiedModerationQueueItem>> listUnifiedQueue({
    List<ModerationQueueDomain>? domains,
    String status = 'open',
    int limit = 50,
    int offset = 0,
    DateTime? since,
    String? authorUserId,
    String? assigneeUserId,
    int? minPriority,
  });

  Future<List<ContentCorrectionQueueItem>> listContentCorrections({
    String status = 'open',
    int limit = 50,
    int offset = 0,
  });

  Future<List<ModerationHistoryEntry>> listReviewHistory({
    required String reviewId,
    int limit = 50,
  });

  Future<List<ModerationHistoryEntry>> listVacancyHistory({
    required String vacancyId,
    int limit = 50,
  });

  Future<void> moderateLegacyReview({
    required String reviewId,
    required String action,
    required String reason,
  });

  Future<void> applyUnifiedAction({
    required ModerationQueueDomain domain,
    required String entityId,
    required String action,
    required String reason,
    int? expectedRowVersion,
  });
}
