// FILE: lib/src/ui/chats/direct_chat_info_screen.dart
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'core/i_chat_service.dart';
import 'media/chat_media_sheet.dart';

class DirectChatInfoScreen extends StatelessWidget {
  const DirectChatInfoScreen({
    super.key,
    required this.service,
    required this.peerId,
    required this.peerName,
    this.peerAvatarUrl,
    this.onOpenUserProfile, // опционально: если есть ваш экран профиля
  });

  final IChatService service;
  final String peerId;
  final String peerName;
  final String? peerAvatarUrl;
  final void Function(BuildContext)? onOpenUserProfile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = (peerName.isNotEmpty ? peerName[0] : 'U').toUpperCase();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль диалога'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        children: [
          Center(
            child: CircleAvatar(
              radius: 44,
              backgroundColor: theme.colorScheme.primaryContainer,
              backgroundImage: (peerAvatarUrl != null && (peerAvatarUrl ?? '').isNotEmpty)
                  ? CachedNetworkImageProvider(peerAvatarUrl!) : null,
              child: (peerAvatarUrl == null || (peerAvatarUrl ?? '').isEmpty)
                  ? Text(initials, style: theme.textTheme.headlineMedium)
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              peerName.isEmpty ? 'Пользователь' : peerName,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),

          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Фото и файлы диалога'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                backgroundColor: theme.colorScheme.surface,
                builder: (_) => ChatMediaSheet(messagesStream: service.watchMessages()),
              );
            },
          ),
          const Divider(indent: 56, height: 1),

          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Перейти в профиль пользователя'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              if (onOpenUserProfile != null) {
                onOpenUserProfile!(context);
              } else {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Профиль пользователя')),
                    body: Center(child: Text('Профиль пользователя: $peerName')),
                  ),
                ));
              }
            },
          ),
        ],
      ),
    );
  }
}
