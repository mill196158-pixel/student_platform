import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
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

  static Future<void> _openDm(BuildContext context, PushPayload payload) async {
    final peerId = payload.peerId;
    if (peerId == null || peerId.isEmpty) {
      MainTabScope.switchToTab(context, MainTab.home);
      return;
    }

    String peerName = 'Личный чат';
    String? avatar;
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('name, surname, avatar_url')
          .eq('id', peerId)
          .maybeSingle();
      if (row != null) {
        final name = (row['name'] ?? '').toString().trim();
        final surname = (row['surname'] ?? '').toString().trim();
        peerName = [name, surname].where((s) => s.isNotEmpty).join(' ').trim();
        if (peerName.isEmpty) peerName = 'Личный чат';
        avatar = (row['avatar_url'] as String?)?.trim();
      }
    } catch (_) {
      // RLS may hide peer; still open chat shell with id.
    }

    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DirectChatScreen(
          peerId: peerId,
          peerName: peerName,
          peerAvatarUrl: avatar,
        ),
      ),
    );
  }
}
