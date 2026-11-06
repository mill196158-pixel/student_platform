import 'dart:async';
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
import 'package:student_platform/src/ui/learning/tabs/chat/navigation/group_action_deeplink.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/navigation/main_tab_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';

/// Resolves push payloads to known screens. Never trusts server route strings.
class PushNavigation {
  PushNavigation._();

  static Future<void> _pushRoute(NavigatorState navigator, Route<dynamic> route,
      {required bool guarded, OnlineSideEffectBarrier? barrier}) async {
    if (guarded && (barrier == null || !barrier.isOpen)) return;
    final result = navigator.push(route);
    if (guarded) {
      final removeHook = barrier!.onClose(() {
        if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      });
      unawaited(result.whenComplete(removeHook));
    } else {
      await result;
    }
  }

  @visibleForTesting
  static Future<void> debugPushGuarded(NavigatorState navigator,
          Route<dynamic> route, OnlineSideEffectBarrier barrier) =>
      _pushRoute(navigator, route, guarded: true, barrier: barrier);

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
    bool Function()? isCurrent,
    OnlineSideEffectBarrier? barrier,
  }) async {
    bool current() {
      try {
        return isCurrent?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    if (!current() ||
        (isCurrent != null && (barrier == null || !barrier.isOpen))) return;
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
      if (isCurrent == null) stash(payload);
      return;
    }

    final tabContext =
        (context != null && context.mounted) ? context : rootNavigatorContext;
    final pushContext = rootNavigatorContext ?? tabContext;
    if (tabContext == null && pushContext == null) {
      if (isCurrent == null) stash(payload);
      return;
    }

    _lastOpenedKey = key;
    _lastOpenedAt = now;
    _pending = null;

    switch (payload.type) {
      case 'dm_message':
        await _openDm(pushContext ?? tabContext!, payload, current,
            isCurrent != null, barrier);
        break;
      case 'team_message':
      case 'team_reply':
        await _openTeamChat(pushContext ?? tabContext!, payload, tabContext,
            current, isCurrent != null, barrier);
        break;
      case 'friend_request':
      case 'friend_accepted':
        await _openFriend(
            pushContext ?? tabContext!, payload, isCurrent != null, barrier);
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
      case 'topic_selection_created':
      case 'topic_deadline_soon':
      case 'topic_reassigned':
      case 'topic_pick_changed':
      case 'collection_created':
      case 'collection_deadline_soon':
      case 'collection_contribution_private':
        // Deep-link helper has asynchronous work without an owner guard.
        if (isCurrent != null) return;
        await _openGroupAction(pushContext ?? tabContext!, payload, tabContext);
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

  /// Resolve peer display name/avatar.
  ///
  /// Direct `users` SELECT is blocked by RLS for other people — only self rows
  /// are readable. Use SECURITY DEFINER `get_user_profile` instead.
  static Future<({String name, String? avatar})> resolvePeerProfile(
    String peerId,
  ) async {
    if (peerId.trim().isEmpty) {
      return (name: kDmTitleFallback, avatar: null);
    }
    try {
      final res = await Supabase.instance.client.rpc(
        'get_user_profile',
        params: {'p_id': peerId},
      );
      Map<String, dynamic>? row;
      if (res is List && res.isNotEmpty) {
        row = Map<String, dynamic>.from(res.first as Map);
      } else if (res is Map) {
        row = Map<String, dynamic>.from(res);
      }
      if (row != null) {
        final name = (row['name'] ?? '').toString().trim();
        final surname = (row['surname'] ?? '').toString().trim();
        final full =
            [name, surname].where((s) => s.isNotEmpty).join(' ').trim();
        final avatar = (row['avatar_url'] as String?)?.trim();
        return (
          name: normalizeDmTitle(full),
          avatar: (avatar == null || avatar.isEmpty) ? null : avatar,
        );
      }
    } catch (_) {}
    return (name: kDmTitleFallback, avatar: null);
  }

  /// Copy [title]/[body] into payload data so open-from-toast can use the
  /// already-shown name without waiting on a second profile fetch.
  static PushPayload? withDisplayFields(
    PushPayload? payload, {
    String? title,
    String? body,
  }) {
    if (payload == null) return null;
    final raw = Map<String, String>.from(payload.raw);
    final t = title?.trim();
    final b = body?.trim();
    if (t != null && t.isNotEmpty) raw['title'] = t;
    if (b != null && b.isNotEmpty) raw['body'] = b;
    return PushPayload.tryParse(raw) ?? payload;
  }

  static Future<void> _openDm(
      BuildContext context,
      PushPayload payload,
      bool Function() current,
      bool guarded,
      OnlineSideEffectBarrier? barrier) async {
    var peerId = payload.peerId;
    final chatId = payload.chatId;
    if ((peerId == null || peerId.isEmpty) &&
        chatId != null &&
        chatId.isNotEmpty) {
      peerId = await _resolveDmPeerId(chatId);
      if (!current()) return;
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
    var peerName =
        isUnresolvedDmTitle(payloadTitle) ? kDmTitleFallback : payloadTitle;
    String? avatar;

    final profile = await resolvePeerProfile(resolvedPeerId);
    if (!current()) return;
    if (!isUnresolvedDmTitle(profile.name)) {
      peerName = profile.name;
    }
    avatar = profile.avatar;

    final navContext = rootNavigatorContext ?? context;
    if (!navContext.mounted) return;
    await _pushRoute(
        Navigator.of(navContext),
        MaterialPageRoute(
          builder: (_) => DirectChatScreen(
            peerId: resolvedPeerId,
            peerName: peerName,
            peerAvatarUrl: avatar,
            initialChatId: chatId,
          ),
        ),
        guarded: guarded,
        barrier: barrier);
  }

  static Future<void> _openTeamChat(
    BuildContext pushContext,
    PushPayload payload,
    BuildContext? tabContext,
    bool Function() current,
    bool guarded,
    OnlineSideEffectBarrier? barrier,
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
        if (!current()) return;
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
      if (!current()) return;
      if (row != null) {
        name = (row['name'] ?? name).toString();
        teacher = (row['teacher'] ?? '').toString();
        icon = (row['icon'] ?? '').toString();
        groupName = (row['group_name'] ?? '').toString();
      }
    } catch (_) {}
    if (!current()) return;

    final team = Team(
      id: teamId,
      name: name,
      teacher: teacher,
      icon: icon,
      groupCode: groupName,
    );

    final navContext = rootNavigatorContext ?? pushContext;
    if (!navContext.mounted) return;

    await _pushRoute(
        Navigator.of(navContext),
        MaterialPageRoute(
          builder: (_) => TeamDetailsScreen(team: team, initialTabIndex: 1),
        ),
        guarded: guarded,
        barrier: barrier);
  }

  /// Opens team chat for group-action cards and scrolls to [cardMessageId].
  static Future<void> _openGroupAction(
    BuildContext pushContext,
    PushPayload payload,
    BuildContext? tabContext,
  ) async {
    final navContext = rootNavigatorContext ?? pushContext;
    if (!navContext.mounted) return;

    final entityId = payload.selectionId ??
        payload.collectionId ??
        payload.assignmentId ??
        '';
    final entityType = payload.type.contains('collection')
        ? 'collection_deadline'
        : 'topic_deadline';

    if (tabContext != null && tabContext.mounted) {
      MainTabScope.switchToTab(tabContext, MainTab.learning);
    }

    await openGroupActionDeeplink(
      navContext,
      GroupActionDeeplinkArgs(
        chatId: payload.chatId,
        cardMessageId: payload.cardMessageId ?? payload.messageId,
        entityType: entityType,
        entityId: entityId,
        teamId: payload.teamId,
      ),
    );
  }

  static Future<void> _openFriend(
    BuildContext context,
    PushPayload payload,
    bool guarded,
    OnlineSideEffectBarrier? barrier,
  ) async {
    final friendId = payload.friendUserId;
    final navContext = rootNavigatorContext ?? context;
    if (!navContext.mounted) return;

    if (friendId != null && friendId.isNotEmpty) {
      await _pushRoute(
          Navigator.of(navContext),
          MaterialPageRoute(
            builder: (_) => FriendProfileScreen(userId: friendId),
          ),
          guarded: guarded,
          barrier: barrier);
      return;
    }

    await _pushRoute(Navigator.of(navContext),
        MaterialPageRoute(builder: (_) => const MyFriendsScreen()),
        guarded: guarded, barrier: barrier);
  }
}
