import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/navigation/root_nav.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';
import 'package:student_platform/src/ui/friends/my_friends_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/navigation/main_tab_scope.dart';

/// Resolves push payloads to known screens. Never trusts server route strings.
class PushNavigation {
  PushNavigation._();

  static PushPayload? _pending;
  static String? _lastOpenedKey;
  static DateTime? _lastOpenedAt;
  static bool _ready = false;

  static void markReady() => _ready = true;

  static void markNotReady() => _ready = false;

  static void stash(PushPayload payload) {
    _pending = payload;
  }

  static Future<void> handle(
    BuildContext? context,
    PushPayload payload, {
    bool fromColdStart = false,
    bool force = false,
  }) async {
    final key = payload.dedupeKey;
    final now = DateTime.now();
    if (!force &&
        !fromColdStart &&
        _lastOpenedKey == key &&
        _lastOpenedAt != null &&
        now.difference(_lastOpenedAt!) < const Duration(milliseconds: 800)) {
      return;
    }

    if (!_ready || Supabase.instance.client.auth.currentUser == null) {
      stash(payload);
      return;
    }

    final tabContext =
        (context != null && context.mounted) ? context : rootNavigatorContext;
    final pushContext = rootNavigatorContext ?? tabContext;
    if (tabContext == null && pushContext == null) {
      stash(payload);
      return;
    }

    _lastOpenedKey = key;
    _lastOpenedAt = now;
    _pending = null;

    switch (payload.type) {
      case 'dm_message':
        await _openDm(pushContext ?? tabContext!, payload);
        break;
      case 'team_message':
      case 'team_reply':
        await _openTeamChat(pushContext ?? tabContext!, payload, tabContext);
        break;
      case 'friend_request':
      case 'friend_accepted':
        await _openFriend(pushContext ?? tabContext!, payload);
        break;
      case 'assignment':
        final ctx = pushContext ?? tabContext;
        if (ctx != null && ctx.mounted) ctx.push('/my-diary');
        break;
      case 'schedule_change':
        if (tabContext != null) {
          MainTabScope.switchToTab(tabContext, MainTab.schedule);
        }
        break;
      case 'announcement':
      case 'material':
        if (tabContext != null) {
          MainTabScope.switchToTab(tabContext, MainTab.info);
        }
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

  static Future<({String name, String? avatar})> resolvePeerProfile(
    String peerId,
  ) async {
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('name, surname, avatar_url')
          .eq('id', peerId)
          .maybeSingle();
      if (row != null) {
        final name = (row['name'] ?? '').toString().trim();
        final surname = (row['surname'] ?? '').toString().trim();
        final full = [name, surname].where((s) => s.isNotEmpty).join(' ').trim();
        final avatar = (row['avatar_url'] as String?)?.trim();
        return (
          name: normalizeDmTitle(full),
          avatar: (avatar == null || avatar.isEmpty) ? null : avatar,
        );
      }
    } catch (_) {}
    return (name: kDmTitleFallback, avatar: null);
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
      if (context.mounted) {
        MainTabScope.switchToTab(context, MainTab.home);
      }
      return;
    }
    final resolvedPeerId = peerId;

    final payloadTitle = normalizeDmTitle(
      payload.raw['title'] ?? payload.raw['peer_name'],
    );
    var peerName = isUnresolvedDmTitle(payloadTitle)
        ? kDmTitleFallback
        : payloadTitle;
    String? avatar;

    final profile = await resolvePeerProfile(resolvedPeerId);
    if (!isUnresolvedDmTitle(profile.name)) {
      peerName = profile.name;
    }
    avatar = profile.avatar;

    final navContext = rootNavigatorContext ?? context;
    if (!navContext.mounted) return;
    await Navigator.of(navContext).push(
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

  static Future<void> _openTeamChat(
    BuildContext pushContext,
    PushPayload payload,
    BuildContext? tabContext,
  ) async {
    var teamId = payload.teamId;
    final chatId = payload.chatId;

    if ((teamId == null || teamId.isEmpty) &&
        chatId != null &&
        chatId.isNotEmpty) {
      try {
        final row = await Supabase.instance.client
            .from('chats')
            .select('team_id')
            .eq('id', chatId)
            .maybeSingle();
        teamId = (row?['team_id'] ?? '').toString();
        if (teamId.isEmpty) teamId = null;
      } catch (_) {}
    }

    if (teamId == null || teamId.isEmpty) {
      if (tabContext != null && tabContext.mounted) {
        MainTabScope.switchToTab(tabContext, MainTab.learning);
      }
      return;
    }

    String name = 'Команда';
    String teacher = '';
    String icon = '';
    String groupName = '';
    try {
      final row = await Supabase.instance.client
          .from('teams')
          .select('id, name, teacher, icon, group_name')
          .eq('id', teamId)
          .maybeSingle();
      if (row != null) {
        name = (row['name'] ?? name).toString();
        teacher = (row['teacher'] ?? '').toString();
        icon = (row['icon'] ?? '').toString();
        groupName = (row['group_name'] ?? '').toString();
      }
    } catch (_) {}

    final team = Team(
      id: teamId,
      name: name,
      teacher: teacher,
      icon: icon,
      groupCode: groupName,
    );

    final navContext = rootNavigatorContext ?? pushContext;
    if (!navContext.mounted) return;

    await Navigator.of(navContext).push(
      MaterialPageRoute(
        builder: (_) => TeamDetailsScreen(team: team, initialTabIndex: 1),
      ),
    );
  }

  static Future<void> _openFriend(
    BuildContext context,
    PushPayload payload,
  ) async {
    final friendId = payload.friendUserId;
    final navContext = rootNavigatorContext ?? context;
    if (!navContext.mounted) return;

    if (friendId != null && friendId.isNotEmpty) {
      await Navigator.of(navContext).push(
        MaterialPageRoute(
          builder: (_) => FriendProfileScreen(userId: friendId),
        ),
      );
      return;
    }

    await Navigator.of(navContext).push(
      MaterialPageRoute(builder: (_) => const MyFriendsScreen()),
    );
  }
}
