import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth_session_scope.dart';
import '../../core/online_side_effect_barrier.dart';
import '../../core/reconnect_chat_intent.dart';
import '../../core/session_capabilities.dart';
import '../chats/direct_chat_screen.dart';
import '../learning/models/team.dart';
import '../learning/team_details_screen.dart';

@visibleForTesting
VoidCallback? debugReconnectSummaryDispatched;
@visibleForTesting
Duration? debugReconnectSummaryTimeout;

/// Restores an in-memory intent only after the ordinary online admission.
class ReconnectChatHost extends StatefulWidget {
  const ReconnectChatHost({super.key, required this.scope,
    required this.capabilities, required this.barrier, required this.child});
  final AuthSessionScope scope;
  final SessionCapabilities capabilities;
  final OnlineSideEffectBarrier barrier;
  final Widget child;
  @override
  State<ReconnectChatHost> createState() => _ReconnectChatHostState();
}

class _ReconnectChatHostState extends State<ReconnectChatHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
  }

  Future<void> _restore() async {
    if (!mounted) return;
    final claim = ReconnectChatIntent.instance.claim();
    if (claim == null || !identical(claim.scope, widget.scope)) return;
    final caps = widget.capabilities, barrier = widget.barrier;
    final permit = caps.capture(SessionCapability.networkRead);
    final route = ModalRoute.of(context);
    final client = Supabase.instance.client;
    bool current() => mounted && route?.isCurrent == true && claim.current &&
        identical(widget.capabilities, caps) && identical(widget.barrier, barrier) &&
        identical(client, Supabase.instance.client) && barrier.isOpen &&
        permit != null && caps.mode == SessionCapabilityMode.online &&
        caps.permits(permit, SessionCapability.networkRead);
    if (!current()) return;
    try {
      var timeout = const Duration(seconds: 10);
      assert(() { timeout = debugReconnectSummaryTimeout ?? timeout; return true; }());
      final rows = await barrier.run<dynamic>(() async {
        if (!current()) return null;
        assert(() { debugReconnectSummaryDispatched?.call(); return true; }());
        return await client.rpc('get_my_chat_summaries');
      }).timeout(timeout, onTimeout: () => null);
      if (!current() || rows is! List || rows.any((r) => r is! Map)) return;
      final matches = rows.whereType<Map>().where((r) => r['chat_id'] == claim.chatId).toList();
      if (matches.length != 1) return;
      final row = matches.single;
      if (row['hidden_at'] != null) return;
      late final Widget destination;
      if (claim.dm) {
        if (row['chat_type'] != 'dm' || row['peer_id'] != claim.targetId) return;
        final title = row['title'];
        if (title != null && title is! String) return;
        destination = DirectChatScreen(peerId: claim.targetId,
            peerName: title is String ? title : '', initialChatId: claim.chatId);
      } else {
        if (row['chat_type'] != 'team_main' || row['team_id'] != claim.targetId) return;
        final teamChats = rows.whereType<Map>().where((r) =>
            r['chat_type'] == 'team_main' && r['team_id'] == claim.targetId).toList();
        if (teamChats.length != 1 || teamChats.single['chat_id'] != claim.chatId) return;
        final kind = row['team_kind'];
        final name = row['team_name'], teacher = row['team_teacher'];
        final group = row['team_group_name'], icon = row['team_icon'];
        if ((kind != 'subject' && kind != 'group_space') || name is! String ||
            (teacher != null && teacher is! String) ||
            (group != null && group is! String) || (icon != null && icon is! String)) return;
        destination = TeamDetailsScreen(team: Team(id: claim.targetId,
            name: name, teacher: teacher as String? ?? '', groupCode: group as String? ?? '',
            icon: icon as String? ?? '', kind: kind as String), initialTabIndex: 1);
      }
      if (!current()) return;
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => destination));
    } catch (_) {
      // Failed or malformed membership checks never open a route.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
