// FILE: lib/src/ui/chats/data/blocks_api.dart
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BlockRelationship {
  final bool iBlocked;
  final bool dmAvailable;

  const BlockRelationship({
    required this.iBlocked,
    required this.dmAvailable,
  });

  static const available = BlockRelationship(
    iBlocked: false,
    dmAvailable: true,
  );
}

class BlocksApi {
  static final SupabaseClient _sb = Supabase.instance.client;

  static bool isDmBlockedError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('dm_blocked')) return true;
    if (error is PostgrestException) {
      final msg = (error.message).toLowerCase();
      final details = (error.details?.toString() ?? '').toLowerCase();
      final hint = (error.hint?.toString() ?? '').toLowerCase();
      return msg.contains('dm_blocked') ||
          details.contains('dm_blocked') ||
          hint.contains('dm_blocked');
    }
    return false;
  }

  static String shortErrorMessage(Object error, {required String fallback}) {
    if (error is PostgrestException) {
      final msg = (error.message).trim();
      switch (msg) {
        case 'dm_blocked':
          return 'Личные сообщения недоступны';
        case 'cannot_block_self':
          return 'Нельзя заблокировать себя';
        case 'user_not_found':
          return 'Пользователь не найден';
        case 'not_authenticated':
          return 'Нужна авторизация';
        case 'invalid_user':
          return 'Некорректный пользователь';
        case 'bad_partner':
          return 'Некорректный собеседник';
      }
    }
    return fallback;
  }

  static Future<void> blockUser(String userId) async {
    try {
      await _sb.rpc('block_user', params: {'p_user_id': userId});
    } catch (e) {
      debugPrint('[BlocksApi] blockUser error: $e');
      rethrow;
    }
  }

  static Future<void> unblockUser(String userId) async {
    try {
      await _sb.rpc('unblock_user', params: {'p_user_id': userId});
    } catch (e) {
      debugPrint('[BlocksApi] unblockUser error: $e');
      rethrow;
    }
  }

  static Future<BlockRelationship> getBlockRelationship(String userId) async {
    try {
      final res = await _sb.rpc(
        'get_block_relationship',
        params: {'p_user_id': userId},
      );
      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty) {
        row = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res);
      }
      if (row == null) return BlockRelationship.available;
      return BlockRelationship(
        iBlocked: row['i_blocked'] == true,
        dmAvailable: row['dm_available'] != false,
      );
    } catch (e) {
      debugPrint('[BlocksApi] getBlockRelationship error: $e');
      rethrow;
    }
  }

  /// Single RPC for group/team screens — no per-message fetches.
  static Future<Set<String>> getMyBlockedUserIds() async {
    try {
      final res = await _sb.rpc('get_my_blocked_user_ids');
      if (res == null) return <String>{};
      if (res is List) {
        return res.map((e) => e.toString()).where((e) => e.isNotEmpty).toSet();
      }
      return <String>{};
    } catch (e) {
      debugPrint('[BlocksApi] getMyBlockedUserIds error: $e');
      rethrow;
    }
  }
}
