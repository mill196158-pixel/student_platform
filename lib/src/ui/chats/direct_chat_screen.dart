// FILE: lib/src/ui/chats/direct_chat_screen.dart
import 'package:flutter/material.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/chats/core/dm_chat_service.dart';
import 'direct_chat_info_screen.dart';

class DirectChatScreen extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final service = DmChatService(peerId: peerId, initialChatId: initialChatId);

    return UnifiedChatScreen(
      service: service,
      title: peerName.isEmpty ? 'Личный чат' : peerName,
      hideAvatars: true,
      peerAvatarUrl: peerAvatarUrl,
      onOpenPeer: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => BlocProvider.value(
              value: context.read<TeamCubit>(),
              child: DirectChatInfoScreen(
                service: service,
                peerId: peerId,
                peerName: peerName,
                peerAvatarUrl: peerAvatarUrl,
              ),
            ),
          ),
        );
      },
    );
  }
}
