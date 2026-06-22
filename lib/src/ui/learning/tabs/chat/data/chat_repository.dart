import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/utils/safe_debug_log.dart';
import '../../../../../services/file_service.dart';
import '../../../models/chat_file.dart';

class ChatRepository {
  final SupabaseClient supabase;
  final FileService fileService;

  ChatRepository({required this.supabase, required this.fileService});

  Future<String> sendMessageWithFiles(
      String teamId, String text, List<String> fileIds) async {
    final messageType = fileIds.isNotEmpty ? 'file' : 'text';
    final response = await supabase.rpc(
      'send_chat_message_with_files',
      params: {
        'p_team_id': teamId,
        'p_text': text,
        'p_type': messageType,
        'p_file_ids': fileIds,
      },
    );
    if (response is Map && response['id'] != null) {
      return response['id'].toString();
    }
    if (response is List && response.isNotEmpty) {
      final first = Map<String, dynamic>.from(response.first as Map);
      if (first['id'] != null) return first['id'].toString();
    }
    return response.toString();
  }

  /// Toggle reaction (add/remove) for a message via RPC
  Future<dynamic> toggleReaction(String messageId, String emoji) async {
    final res = await supabase.rpc('toggle_message_reaction', params: {
      'p_message_id': messageId,
      'p_emoji': emoji,
    });
    return res;
  }

  /// Load reactions for a single message (aggregate counts and user's reactions)
  Future<Map<String, dynamic>> loadReactionsForMessage(String messageId) async {
    final rows = await supabase
        .from('message_reactions')
        .select('emoji,user_id')
        .eq('message_id', messageId) as List<dynamic>?;

    final counts = <String, int>{};
    final userReacts = <String>[];
    final uid = supabase.auth.currentUser?.id;
    if (rows != null) {
      for (final r in rows) {
        final map = Map<String, dynamic>.from(r as Map);
        final emoji = (map['emoji'] ?? '').toString();
        counts[emoji] = (counts[emoji] ?? 0) + 1;
        if (uid != null && uid.isNotEmpty && (map['user_id'] ?? '') == uid) {
          userReacts.add(emoji);
        }
      }
    }
    return {'counts': counts, 'userReactions': userReacts};
  }

  Future<String> saveChatFile(ChatFile chatFile, String userId) async {
    final response = await supabase.rpc('save_chat_file', params: {
      'p_chat_id': chatFile.chatId,
      'p_file_name': chatFile.fileName,
      'p_file_key': chatFile.fileKey,
      'p_file_url': chatFile.fileUrl,
      'p_file_type': chatFile.fileType,
      'p_file_size': chatFile.fileSize,
      'p_uploaded_by': userId,
      'p_message_id':
          chatFile.messageId?.isEmpty == true ? null : chatFile.messageId,
    });
    return response.toString();
  }

  Future<FileDownloadResult> downloadFile(ChatFile file) async {
    return fileService.downloadFile(
        fileKey: file.fileKey, fileName: file.fileName);
  }

  Future<String> getMainChatId(String teamId) async {
    try {
      final response = await supabase
          .from('chats')
          .select('id')
          .eq('team_id', teamId)
          .eq('type', 'team_main')
          .limit(1)
          .single();
      return (response['id'] as String?) ?? '';
    } catch (e) {
      return '';
    }
  }

  // ➜ NEW: отметить чат прочитанным
  Future<void> markRead({required String chatId, String? messageId}) async {
    await supabase.rpc('mark_chat_read', params: {
      'p_chat_id': chatId,
      if (messageId != null && messageId.isNotEmpty) 'p_message_id': messageId,
    });
  }

  // ➜ NEW: получить счетчик непрочитанных + якорь
  Future<Map<String, dynamic>> getUnreadInChat(String chatId) async {
    final res =
        await supabase.rpc('get_unread_in_chat', params: {'p_chat_id': chatId});
    if (res == null) return {'unread_count': 0, 'first_unread_id': null};
    if (res is List && res.isNotEmpty) {
      final m = Map<String, dynamic>.from(res.first as Map);
      return {
        'unread_count': (m['unread_count'] ?? 0) as int,
        'first_unread_id': (m['first_unread_id'] as String?)
      };
    }
    if (res is Map) {
      final m = Map<String, dynamic>.from(res);
      return {
        'unread_count': (m['unread_count'] ?? 0) as int,
        'first_unread_id': (m['first_unread_id'] as String?)
      };
    }
    return {'unread_count': 0, 'first_unread_id': null};
  }

  /// Snapshot the boundary timestamp from chat_reads.last_read_at for current user (UTC).
  Future<DateTime?> getLastSeenAt({required String chatId}) async {
    try {
      final uid = supabase.auth.currentUser?.id;
      if (uid == null || uid.isEmpty) return null;

      final row = await supabase
          .from('chat_reads')
          .select('last_read_at')
          .eq('chat_id', chatId)
          .eq('user_id', uid)
          .maybeSingle();

      if (row == null) return null;
      final map = Map<String, dynamic>.from(row as Map);
      final v = map['last_read_at'];
      if (v != null) {
        safeDebugLog('[REPO] last_read_at loaded chat=${maskDebugId(chatId)}');
      }
      if (v == null) return null;
      return DateTime.parse(v.toString()).toUtc();
    } catch (_) {
      return null;
    }
  }
}
