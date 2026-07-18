// FILE: lib/src/ui/chats/direct_chat_screen.dart
import 'package:flutter/material.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
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

  @override
  void initState() {
    super.initState();
    _service = DmChatService(
      peerId: widget.peerId,
      initialChatId: widget.initialChatId,
    );
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UnifiedChatScreen(
      service: _service,
      title: widget.peerName.isEmpty ? 'Личный чат' : widget.peerName,
      hideAvatars: true,
      peerAvatarUrl: widget.peerAvatarUrl,
      onOpenPeer: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<TeamCubit>(),
              child: DirectChatInfoScreen(
                service: _service,
                peerId: widget.peerId,
                peerName: widget.peerName,
                peerAvatarUrl: widget.peerAvatarUrl,
              ),
            ),
          ),
        );
      },
    );
  }
}
