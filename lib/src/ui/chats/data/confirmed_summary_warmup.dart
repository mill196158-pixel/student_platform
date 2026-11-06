import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/chats/data/chat_summary_card.dart';

/// Saves only a complete, validated server result under the current project's
/// scoped ticket. No legacy cache import and no partial writes on bad input.
Future<bool> warmConfirmedSummaries({
  required ProjectChatServerCache cache,
  required OnlineSideEffectBarrier barrier,
  required bool Function() isCurrent,
  required Future<Object?> Function() fetch,
  required Map<String, dynamic>? Function(Map<String, dynamic>) mapRow,
}) async {
  final result = await barrier.run(() async {
    if (!isCurrent() || !barrier.isOpen) return false;
    final ticket = await cache.begin(ProjectChatServerCache.summaryChatKey,
        isCurrent: () => isCurrent() && barrier.isOpen);
    if (ticket == null || !isCurrent() || !barrier.isOpen) return false;
    final raw = await fetch();
    if (!isCurrent() || !barrier.isOpen || raw is! List) return false;
    final rows = <Map<String, dynamic>>[];
    for (final value in raw) {
      if (value is! Map || value.keys.any((key) => key is! String)) return false;
      final row = Map<String, dynamic>.from(value);
      if (row['chat_id'] is! String || (row['chat_id'] as String).isEmpty ||
          row['chat_type'] is! String || row['unread_count'] is! int ||
          row['is_pinned'] is! bool || row['is_muted'] is! bool) return false;
      final mapped = mapRow(row);
      if (mapped == null) return false;
      final forward = summaryForwardPreview(row['body']) ??
          summaryForwardPreview(row['content']);
      if (forward != null) mapped['lastMsgPreview'] = forward;
      if (mapped['isDm'] == false && isSummaryActionCard(row)) {
        mapped['lastActionCard'] = true;
      }
      final kind = row['team_kind'];
      if (mapped['isDm'] == false && (kind == 'subject' || kind == 'group_space')) {
        final team = mapped['team'];
        if (team is! Map<String, dynamic>) return false;
        team['kind'] = kind;
        if (kind == 'group_space') {
          mapped['title'] = 'Чат группы';
          team['name'] = 'Чат группы';
        }
      }
      rows.add(mapped);
    }
    if (!isCurrent() || !barrier.isOpen) return false;
    return cache.saveSummaries(ticket, rows);
  });
  return result ?? false;
}
