import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:student_platform/src/ui/friends/friend_profile_screen.dart';
import 'package:student_platform/src/ui/chats/dm_title.dart';

import 'core/i_chat_service.dart';
import 'media/chat_media_sheet.dart';

class DirectChatInfoScreen extends StatelessWidget {
  const DirectChatInfoScreen({
    super.key,
    required this.service,
    required this.peerId,
    required this.peerName,
    this.peerAvatarUrl,
  });

  final IChatService service;
  final String peerId;
  final String peerName;
  final String? peerAvatarUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final displayName = normalizeDmTitle(peerName);

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Column(
        children: [
          Stack(
            children: [
              _GradientHeader(
                topPadding: media.padding.top,
                child: _HeaderIdentity(
                  name: displayName,
                  avatarUrl: peerAvatarUrl,
                  onAvatarTap: () => _openProfile(context),
                ),
              ),
              PositionedDirectional(
                start: 4,
                top: media.padding.top + 4,
                child: const _TopBackButton(),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                24 + media.padding.bottom,
              ),
              children: [
                _DialogMediaCard(
                  onTap: () => _openMediaSheet(context, theme),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openProfile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(userId: peerId),
      ),
    );
  }

  Future<void> _openMediaSheet(BuildContext context, ThemeData theme) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: theme.colorScheme.surface,
      builder: (_) => ChatMediaSheet(messagesStream: service.watchMessages()),
    );
  }
}

class _GradientHeader extends StatelessWidget {
  const _GradientHeader({
    required this.topPadding,
    required this.child,
  });

  final double topPadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(24, topPadding + 50, 24, 20),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(30),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(scheme.primary.withAlpha(32), scheme.surface),
            Color.alphaBlend(
              scheme.primaryContainer.withAlpha(180),
              scheme.surface,
            ),
            Color.alphaBlend(
              scheme.secondaryContainer.withAlpha(96),
              scheme.surface,
            ),
          ],
        ),
      ),
      child: child,
    );
  }
}

class _HeaderIdentity extends StatelessWidget {
  const _HeaderIdentity({
    required this.name,
    required this.avatarUrl,
    required this.onAvatarTap,
  });

  final String name;
  final String? avatarUrl;
  final VoidCallback onAvatarTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LargePeerAvatar(
            name: name,
            avatarUrl: avatarUrl,
            onTap: onAvatarTap,
          ),
          const SizedBox(height: 12),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w800,
              height: 1.12,
            ),
          ),
        ],
      ),
    );
  }
}

class _LargePeerAvatar extends StatelessWidget {
  const _LargePeerAvatar({
    required this.name,
    required this.avatarUrl,
    required this.onTap,
  });

  final String name;
  final String? avatarUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = avatarUrl?.trim();
    final avatar = url == null || url.isEmpty
        ? null
        : CachedNetworkImageProvider(url) as ImageProvider;
    const size = 100.0;
    final radius = BorderRadius.circular(size / 2);

    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: scheme.onSurface.withAlpha(22),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(28),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Ink(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.secondaryContainer,
              image: avatar == null
                  ? null
                  : DecorationImage(
                      image: avatar,
                      fit: BoxFit.cover,
                    ),
            ),
            child: avatar == null ? _AvatarInitial(name: name) : null,
          ),
        ),
      ),
    );
  }
}

class _AvatarInitial extends StatelessWidget {
  const _AvatarInitial({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: Text(
        _initial(name),
        style: theme.textTheme.headlineMedium?.copyWith(
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  String _initial(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'U';
    return trimmed.characters.first.toUpperCase();
  }
}

class _TopBackButton extends StatelessWidget {
  const _TopBackButton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.maybePop(context),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.arrow_back_rounded,
            color: scheme.onSurface,
            size: 24,
          ),
        ),
      ),
    );
  }
}

class _DialogMediaCard extends StatelessWidget {
  const _DialogMediaCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(20);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: radius,
        border: Border.all(color: scheme.outlineVariant.withAlpha(115)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(
              theme.brightness == Brightness.dark ? 42 : 14,
            ),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.photo_library_outlined,
                    color: scheme.onPrimaryContainer,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Text(
                    'Фото и файлы',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
