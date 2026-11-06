import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/online_side_effect_barrier.dart';
import '../../ui/chats/direct_chat_screen.dart';
import '../../ui/learning/models/team.dart';
import '../../ui/learning/team_details_screen.dart';
import '../../ui/learning/tabs/chat/unified_task_details_screen.dart';
import 'push_payload.dart';

/// The server summary supplies the target; the incoming push only selects a
/// supported kind. An absent notification ID does not prove its recipient.
Widget buildGuardedPushQaTarget({
  required PushPayload incoming,
  required PushPayload target,
  required SupabaseClient client,
  required String user,
  required OnlineSideEffectBarrier barrier,
  required bool Function() current,
  required bool dmEnabled,
  required bool teamEnabled,
  bool actionEnabled = false,
}) {
  if (dmEnabled &&
      incoming.type == 'dm_message' &&
      target.type == 'dm_message' &&
      target.peerId != null &&
      target.chatId != null) {
    return DirectChatScreen(
        peerId: target.peerId!,
        peerName: 'Личный чат',
        initialChatId: target.chatId,
        onlineBarrier: barrier,
        sessionIsCurrent: current,
        guardedPushClient: client,
        guardedPushUserId: user);
  }
  if (teamEnabled &&
      (incoming.type == 'team_message' || incoming.type == 'team_reply') &&
      target.type == 'team_message' &&
      target.teamId != null &&
      target.chatId != null) {
    return TeamDetailsScreen(
        team: Team(
            id: target.teamId!,
            name: 'Команда',
            teacher: '',
            groupCode: '',
            icon: '',
            kind: 'unknown'),
        guardedPushClient: client,
        guardedPushUserId: user,
        guardedPushChatId: target.chatId,
        guardedPushBarrier: barrier,
        guardedPushSessionIsCurrent: current);
  }
  const topicEvents = {
    'topic_selection_created',
    'topic_deadline_soon',
    'topic_reassigned',
    'topic_pick_changed',
  };
  const collectionEvents = {
    'collection_created',
    'collection_deadline_soon',
    'collection_contribution_private',
  };
  final isTopic = topicEvents.contains(incoming.type);
  final isCollection = collectionEvents.contains(incoming.type);
  final entity = isTopic ? incoming.selectionId : incoming.collectionId;
  if (actionEnabled &&
      (isTopic || isCollection) &&
      target.type == 'team_message' &&
      target.teamId != null &&
      target.chatId != null &&
      entity != null &&
      entity.trim().isNotEmpty) {
    final kind = isTopic ? 'topic_selection' : 'group_collection';
    return UnifiedTaskDetailsScreen(
      key: ValueKey((
        client,
        barrier,
        current,
        kind,
        target.chatId,
        entity,
        incoming.cardMessageId
      )),
      kind: kind,
      entityId: entity,
      chatId: target.chatId!,
      teamId: target.teamId,
      cardMessageId: incoming.cardMessageId,
      guardedPushClient: client,
      guardedPushBarrier: barrier,
      guardedPushSessionIsCurrent: current,
    );
  }
  return const Scaffold(
      body: Center(child: Text('Откройте чат в разделе «Сообщения».')));
}
