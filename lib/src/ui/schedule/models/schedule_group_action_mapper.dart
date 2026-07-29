import '../../learning/tabs/chat/models/chat_group_actions.dart';
import 'schedule_group_action_event.dart';

/// Maps RPC deadlines to schedule events with dedupe by type+entity+occurs_at.
List<ScheduleGroupActionEvent> mapScheduleGroupActionEvents(
  List<GroupActionDeadline> raw,
) {
  final seen = <String>{};
  final out = <ScheduleGroupActionEvent>[];
  for (final item in raw) {
    final status = (item.status ?? 'open').trim().toLowerCase();
    if (status.isNotEmpty && status != 'open') continue;
    final key =
        '${item.eventType}|${item.entityId}|${item.occursAt.toUtc().millisecondsSinceEpoch}';
    if (!seen.add(key)) continue;
    out.add(ScheduleGroupActionEvent.fromDeadline(item));
  }
  out.sort((a, b) => a.occursAt.compareTo(b.occursAt));
  return out;
}
