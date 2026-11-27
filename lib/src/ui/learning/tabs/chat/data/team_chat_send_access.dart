import 'package:supabase_flutter/supabase_flutter.dart';

enum TeamChatSendAccess { allowed, readOnly, unavailable }

/// A message send requires exact team membership and a live main chat.
/// Composer actions such as proposing an assignment have separate rules.
Future<TeamChatSendAccess> loadTeamChatSendAccess(
  SupabaseClient client, {
  required String userId,
  required String teamId,
  required Future<String> mainChatId,
  required bool Function() isCurrent,
}) async {
  try {
    final membershipQuery = client
        .from('team_members')
        .select('team_id,user_id')
        .eq('team_id', teamId)
        .eq('user_id', userId)
        .limit(1)
        .maybeSingle();
    final (membership, chatId) = await (membershipQuery, mainChatId).wait;
    if (!isCurrent()) return TeamChatSendAccess.unavailable;
    if (membership == null) return TeamChatSendAccess.readOnly;
    if (membership['team_id'] != teamId ||
        membership['user_id'] != userId ||
        chatId.isEmpty) {
      return TeamChatSendAccess.unavailable;
    }

    // This projection includes empty team chats and excludes archived chats.
    final liveChats = await client
        .rpc('get_my_chat_summaries')
        .eq('chat_id', chatId)
        .eq('team_id', teamId)
        .eq('chat_type', 'team_main')
        .select('chat_id,team_id,chat_type')
        .limit(1);
    if (!isCurrent()) return TeamChatSendAccess.unavailable;
    if (liveChats.isEmpty) return TeamChatSendAccess.readOnly;
    final liveChat = liveChats.single;
    return liveChat['chat_id'] == chatId &&
            liveChat['team_id'] == teamId &&
            liveChat['chat_type'] == 'team_main'
        ? TeamChatSendAccess.allowed
        : TeamChatSendAccess.unavailable;
  } catch (_) {
    return TeamChatSendAccess.unavailable;
  }
}
