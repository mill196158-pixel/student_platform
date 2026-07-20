import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';
import 'package:student_platform/src/ui/friends/my_friends_screen.dart';
import 'package:student_platform/src/ui/navigation/main_tab_scope.dart';

/// Resolves push payloads to known screens. Never trusts server route strings.
class PushNavigation {
  PushNavigation._();

  static PushPayload? _pending;
  static String? _lastOpenedKey;
  static bool _ready = false;

  static void markReady() => _ready = true;

  static void markNotReady() => _ready = false;

  static void stash(PushPayload payload) {
    _pending = payload;
  }

  static Future<void> handle(
    BuildContext context,
    PushPayload payload, {
    bool fromColdStart = false,
  }) async {
    final key = payload.dedupeKey;
    if (_lastOpenedKey == key && !fromColdStart) return;

    if (!_ready || Supabase.instance.client.auth.currentUser == null) {
      stash(payload);
      return;
    }

    _lastOpenedKey = key;
    _pending = null;

    switch (payload.type) {
      case 'dm_message':
        await _openDm(context, payload);
        break;
      case 'team_message':
      case 'team_reply':
        MainTabScope.switchToTab(context, MainTab.learning);
        break;
      case 'friend_request':
      case 'friend_accepted':
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const MyFriendsScreen()),
        );
        break;
      case 'assignment':
        if (context.mounted) context.push('/my-diary');
        break;
      case 'schedule_change':
        MainTabScope.switchToTab(context, MainTab.schedule);
        break;
      case 'announcement':
      case 'material':
        MainTabScope.switchToTab(context, MainTab.info);
        break;
      default:
        break;
    }
  }

  static Future<void> flushPending(BuildContext context) async {
    final pending = _pending;
    if (pending == null) return;
    await handle(context, pending, fromColdStart: true);
  }

  static Future<String?> _resolveDmPeerId(String chatId) async {
    final me = Supabase.instance.client.auth.currentUser?.id;
    if (me == null || me.isEmpty || chatId.isEmpty) return null;
    try {
      final rows = await Supabase.instance.client
          .from('chat_members')
          .select('user_id')
          .eq('chat_id', chatId);
      for (final row in rows as List) {
        final id = (row['user_id'] ?? '').toString();
        if (id.isNotEmpty && id != me) return id;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _openDm(BuildContext context, PushPayload payload) async {
    var peerId = payload.peerId;
    final chatId = payload.chatId;
    if ((peerId == null || peerId.isEmpty) &&
        chatId != null &&
        chatId.isNotEmpty) {
      peerId = await _resolveDmPeerId(chatId);
    }
    if (peerId == null || peerId.isEmpty) {
      MainTabScope.switchToTab(context, MainTab.home);
      return;
    }
    final resolvedPeerId = peerId;

    String peerName = kDmTitleFallback;
    String? avatar;
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('name, surname, avatar_url')
          .eq('id', resolvedPeerId)
          .maybeSingle();
      if (row != null) {
        final name = (row['name'] ?? '').toString().trim();
        final surname = (row['surname'] ?? '').toString().trim();
        peerName = normalizeDmTitle(
          [name, surname].where((s) => s.isNotEmpty).join(' ').trim(),
        );
        avatar = (row['avatar_url'] as String?)?.trim();
      }
    } catch (_) {
      // RLS may hide peer; still open chat shell with id.
    }

    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DirectChatScreen(
          peerId: resolvedPeerId,
          peerName: peerName,
          peerAvatarUrl: avatar,
          initialChatId: chatId,
        ),
      ),
    );
  }
}
