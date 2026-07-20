// FILE: lib/src/ui/chats/direct_chat_screen.dart
import 'package:flutter/material.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'direct_chat_info_screen.dart';

class DirectChatScreen extends StatefulWidget {
  const DirectChatScreen({
    super.key,
    required this.peerId,
    required this.peerName,
    this.peerAvatarUrl,
    this.initialChatId,
  });

  final String peerId;
  final String peerName;
  final String? peerAvatarUrl;
  final String? initialChatId;

  @override
  State<DirectChatScreen> createState() => _DirectChatScreenState();
}

class _DirectChatScreenState extends State<DirectChatScreen> {
  late final DmChatService _service;
  late String _peerName;
  String? _peerAvatarUrl;

  bool get _needsPeerProfile =>
      isUnresolvedDmTitle(_peerName) || (_peerAvatarUrl ?? '').isEmpty;

  @override
  void initState() {
    super.initState();
    _peerName = normalizeDmTitle(widget.peerName);
    _peerAvatarUrl = widget.peerAvatarUrl;
    _service = DmChatService(
      peerId: widget.peerId,
      initialChatId: widget.initialChatId,
    );
    if (_needsPeerProfile) {
      _loadPeerProfile();
    }
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = normalizeDmTitle(_peerName);
    return UnifiedChatScreen(
      service: _service,
      title: title,
      hideAvatars: true,
      peerAvatarUrl: _peerAvatarUrl,
      onOpenPeer: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<TeamCubit>(),
              child: DirectChatInfoScreen(
                service: _service,
                peerId: widget.peerId,
                peerName: title,
                peerAvatarUrl: _peerAvatarUrl,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadPeerProfile() async {
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('name, surname, avatar_url')
          .eq('id', widget.peerId)
          .maybeSingle();
      if (row == null || !mounted) return;
      final name = (row['name'] ?? '').toString().trim();
      final surname = (row['surname'] ?? '').toString().trim();
      final fullName = [name, surname].where((s) => s.isNotEmpty).join(' ');
      final avatar = (row['avatar_url'] ?? '').toString().trim();
      if (fullName.isEmpty && avatar.isEmpty) return;
      setState(() {
        if (fullName.isNotEmpty) _peerName = fullName;
        if (avatar.isNotEmpty) _peerAvatarUrl = avatar;
      });
    } catch (_) {
      // Profile may be hidden by RLS/network — keep neutral "Пользователь".
    }
  }
}
