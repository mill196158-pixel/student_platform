import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/chats/core/chat_message_memory_cache.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';

/// Thin RPC wrappers for personal DM archive / hide-for-me.
class ChatArchiveApi {
  ChatArchiveApi._();

  static SupabaseClient get _sb => Supabase.instance.client;

  static Future<void> setPersonalChatArchived({
    required String chatId,
    required bool archived,
  }) async {
    await _sb.rpc(
      'set_personal_chat_archived',
      params: {
        'p_chat_id': chatId,
        'p_archived': archived,
      },
    );
  }

  static Future<void> hidePersonalChatForMe({required String chatId}) async {
    await _sb.rpc(
      'hide_personal_chat_for_me',
      params: {'p_chat_id': chatId},
    );
    DmApi.invalidateClearedAt(chatId);
    ChatMessageMemoryCache.clearChat(chatId);
  }

  static Future<List<Map<String, dynamic>>> getMyArchivedChatSummaries() async {
    final res = await _sb.rpc('get_my_archived_chat_summaries');
    return (res as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
