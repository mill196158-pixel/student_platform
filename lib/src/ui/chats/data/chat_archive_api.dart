import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

import 'package:student_platform/src/ui/chats/core/chat_message_memory_cache.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
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

  static Future<void> hidePersonalChatForMe({required String chatId}) =>
      hidePersonalChatWith(
        chatId: chatId,
        cache: ProjectChatServerCache.qaInstance,
        remoteHide: () async {
          await _sb
              .rpc('hide_personal_chat_for_me', params: {'p_chat_id': chatId});
        },
        clearLocal: () {
          DmApi.invalidateClearedAt(chatId);
          ChatMessageMemoryCache.clearChat(chatId);
        },
      );

  @visibleForTesting
  static Future<void> hidePersonalChatWith(
      {required String chatId,
      required ProjectChatServerCache? cache,
      required Future<void> Function() remoteHide,
      required void Function() clearLocal}) async {
    final hold = cache == null ? null : await cache.beginHide(chatId);
    if (cache != null && (hold == null || !cache.isHoldCurrent(hold))) {
      throw StateError('Unable to secure cached chat before hiding');
    }
    final summariesHold = cache == null
        ? null
        : await cache.beginHide(ProjectChatServerCache.summaryChatKey);
    if (cache != null &&
        (summariesHold == null ||
            !cache.isHoldCurrent(hold!) ||
            !cache.isHoldCurrent(summariesHold))) {
      throw StateError('Unable to secure cached chat list before hiding');
    }
    // A failed/ambiguous RPC deliberately leaves both durable holds in place.
    await remoteHide();
    if (cache != null &&
        (!cache.isHoldCurrent(hold!) ||
            !cache.isHoldCurrent(summariesHold!) ||
            !await cache.finishHide(hold) ||
            !await cache.finishHide(summariesHold))) {
      throw StateError('Unable to finish cached chat hide');
    }
    clearLocal();
  }

  static Future<List<Map<String, dynamic>>> getMyArchivedChatSummaries() async {
    final res = await _sb.rpc('get_my_archived_chat_summaries');
    return (res as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
