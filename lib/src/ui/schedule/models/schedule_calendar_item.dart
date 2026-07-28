import '../../learning/models/assignment.dart';
import 'schedule_group_action_event.dart';

/// Presentation-level calendar row for Schedule (Stage 13.10).
/// Assignments and group actions stay in separate SoT; this unifies UI only.
class ScheduleCalendarItem {
  ScheduleCalendarItem.assignment(this.assignment)
      : groupAction = null,
        kind = ScheduleCalendarItemKind.assignment;

  ScheduleCalendarItem.groupAction(ScheduleGroupActionEvent action)
      : assignment = null,
        groupAction = action,
        kind = action.isTopic
            ? ScheduleCalendarItemKind.subjectTask
            : ScheduleCalendarItemKind.groupTask;

  final ScheduleCalendarItemKind kind;
  final Assignment? assignment;
  final ScheduleGroupActionEvent? groupAction;

  DateTime get occursAt =>
      groupAction?.occursAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  String get title {
    if (groupAction != null) {
      final t = groupAction!.title.trim();
      return t.isEmpty ? 'Задание' : t;
    }
    return (assignment?.title ?? '').trim();
  }

  /// Status-only when useful; never sectional "Задание группы/по предмету".
  String? get badge {
    switch (kind) {
      case ScheduleCalendarItemKind.subjectTask:
      case ScheduleCalendarItemKind.groupTask:
        return groupAction?.statusLabel;
      case ScheduleCalendarItemKind.assignment:
        return null;
    }
  }

  String get dedupeKey =>
      groupAction?.dedupeKey ??
      'assignment|${assignment?.id}|${occursAt.toUtc().millisecondsSinceEpoch}';
}

enum ScheduleCalendarItemKind {
  assignment,
  subjectTask,
  groupTask,
}
