import '../../learning/tabs/chat/models/chat_group_actions.dart';

/// Calendar event for topic selection / group collection deadlines (Stage 13.9).
class ScheduleGroupActionEvent {
  const ScheduleGroupActionEvent({
    required this.eventType,
    required this.entityId,
    required this.title,
    required this.occursAt,
    this.chatId,
    this.teamId,
    this.groupId,
    this.cardMessageId,
    this.teamName,
    this.status,
    this.myPickText,
    this.canDelete = false,
  });

  final String eventType;
  final String entityId;
  final String title;
  final DateTime occursAt;
  final String? chatId;
  final String? teamId;
  final String? groupId;
  final String? cardMessageId;
  final String? teamName;
  final String? status;
  final String? myPickText;
  final bool canDelete;

  bool get isTopic => eventType == 'topic_deadline';
  bool get isCollection => eventType == 'collection_deadline';

  /// Neutral badge for Schedule UI — no sectional/kind language, no enums.
  /// Prefer empty; status is shown separately via [statusLabel].
  String get neutralBadge => '';

  @Deprecated('Use neutralBadge / real title instead of technical kind labels')
  String get kindLabel => neutralBadge;

  String get statusLabel {
    final raw = (status ?? '').trim();
    if (raw.isEmpty) return 'Открыто';
    switch (raw) {
      case 'open':
        return 'Открыто';
      case 'closed':
        return 'Закрыто';
      case 'cancelled':
        return 'Отменено';
      default:
        // Never leak raw technical tokens into Schedule UI.
        return 'Открыто';
    }
  }

  factory ScheduleGroupActionEvent.fromDeadline(GroupActionDeadline deadline) {
    return ScheduleGroupActionEvent(
      eventType: deadline.eventType,
      entityId: deadline.entityId,
      title: deadline.title,
      occursAt: deadline.occursAt,
      chatId: deadline.chatId,
      teamId: deadline.teamId,
      groupId: deadline.groupId,
      cardMessageId: deadline.cardMessageId,
      teamName: deadline.teamName,
      status: deadline.status,
      myPickText: deadline.myPickText,
      canDelete: deadline.canDelete,
    );
  }

  String get dedupeKey =>
      '$eventType|$entityId|${occursAt.toUtc().millisecondsSinceEpoch}';
}
