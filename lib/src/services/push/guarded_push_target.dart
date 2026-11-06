import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/services/push/push_payload.dart';

/// A target is authorised by the current session, not proven to be the
/// recipient of the original push. Never copy display text or other payload
/// fields into the result.
Future<PushPayload?> resolveCurrentPushTarget({
  required PushPayload payload,
  required OnlineSideEffectBarrier barrier,
  required bool Function() isCurrent,
  required Future<dynamic> Function() fetchSummaries,
}) async {
  bool allowed() {
    try {
      return barrier.isOpen && isCurrent();
    } catch (_) {
      return false;
    }
  }

  final chatId = payload.chatId;
  if (!allowed() || chatId == null || chatId.isEmpty) return null;
  const teamTypes = {
    'team_message',
    'team_reply',
    'topic_selection_created',
    'topic_deadline_soon',
    'topic_reassigned',
    'topic_pick_changed',
    'collection_created',
    'collection_deadline_soon',
    'collection_contribution_private'
  };
  if (payload.type != 'dm_message' && !teamTypes.contains(payload.type))
    return null;
  try {
    return await barrier.run<PushPayload?>(() async {
      if (!allowed()) return null;
      final rows = await fetchSummaries();
      if (!allowed() || rows is! List || rows.any((row) => row is! Map)) return null;
      final matches = rows
          .whereType<Map>()
          .where((row) => row['chat_id'] == chatId)
          .toList();
      if (matches.length != 1) return null;
      final row = matches.single;
      if (row['hidden_at'] != null) return null;
      final type = row['chat_type'];
      if (payload.type == 'dm_message') {
        final peer = row['peer_id'];
        if (type != 'dm' || peer is! String || peer.isEmpty) return null;
        return PushPayload(
            version: 1, type: 'dm_message', chatId: chatId, peerId: peer);
      }
      final team = row['team_id'];
      if (type != 'team_main' || team is! String || team.isEmpty) return null;
      return PushPayload(
          version: 1, type: 'team_message', chatId: chatId, teamId: team);
    });
  } catch (_) {
    return null;
  }
}
