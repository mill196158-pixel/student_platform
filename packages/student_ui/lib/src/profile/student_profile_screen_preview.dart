import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../content/content_models.dart';
import '../content/student_profile_feed_card.dart';

/// Presentation-only full profile composition for Admin phone preview
/// (and reusable by Mobile). No Supabase/routing/service imports.
class StudentProfileScreenPreview extends StatelessWidget {
  const StudentProfileScreenPreview({
    super.key,
    required this.displayName,
    required this.groupLabel,
    this.universityLabel,
    this.statusLabel,
    this.guest = false,
    this.footer,
    this.avatarBytes,
    this.avatarUrl,
    this.avatarImage,
    this.pointsChip,
    this.messagesBadge = 0,
    this.friendsBadge = 0,
    this.feedCards = const [],
    this.feedLoadError = false,
    this.onFeedRetry,
    this.selectedFeedId,
    this.onFeedVisible,
    this.onFeedTap,
    this.showStudySection = true,
    this.showDiary = true,
    this.onDiaryTap,
    this.onMapTap,
    this.onReviewsTap,
    this.onMessagesTap,
    this.onFriendsTap,
    this.detailCard,
    this.onBack,
    this.padding = const EdgeInsets.fromLTRB(16, 20, 16, 24),
  });

  final bool guest;
  final Widget? footer;
  final String displayName;
  final String groupLabel;
  final String? universityLabel;
  final String? statusLabel;
  final Uint8List? avatarBytes;
  final String? avatarUrl;
  final ImageProvider? avatarImage;
  final Widget? pointsChip;
  final int messagesBadge;
  final int friendsBadge;
  final List<ManagedProfileFeedCard> feedCards;
  final bool feedLoadError;
  final VoidCallback? onFeedRetry;
  final String? selectedFeedId;
  final ValueChanged<ManagedProfileFeedCard>? onFeedVisible;
  final ValueChanged<ManagedProfileFeedCard>? onFeedTap;
  final bool showStudySection;
  final bool showDiary;
  final VoidCallback? onDiaryTap;
  final VoidCallback? onMapTap;
  final VoidCallback? onReviewsTap;
  final VoidCallback? onMessagesTap;
  final VoidCallback? onFriendsTap;

  /// When non-null, show in-phone feed detail with back instead of list chrome.
  final ManagedProfileFeedCard? detailCard;
  final VoidCallback? onBack;
  final EdgeInsetsGeometry padding;

  static const _lavender = Color(0xFFDCD0FA);
  static const _accent = Color(0xFF7C63D8);

  /// Uniform vertical gap between major profile blocks.
  static const double sectionGap = 14;

  @override
  Widget build(BuildContext context) {
    if (detailCard != null) {
      return _ProfileFeedDetailView(
        card: detailCard!,
        onBack: onBack,
      );
    }

    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SoftHeader(
              displayName: displayName,
              guest: guest,
              groupLabel: groupLabel,
              universityLabel: universityLabel,
              statusLabel: statusLabel,
              avatarBytes: avatarBytes,
              avatarUrl: avatarUrl,
              avatarImage: avatarImage,
            ),
            if (pointsChip != null) ...[
              const SizedBox(height: sectionGap),
              Center(child: pointsChip!),
            ],
            const SizedBox(height: sectionGap),
            _ActionsRow(
              messagesBadge: messagesBadge,
              friendsBadge: friendsBadge,
              onMessagesTap: onMessagesTap,
              onFriendsTap: onFriendsTap,
            ),
            if (feedLoadError) ...[
              const SizedBox(height: sectionGap),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.error_outline),
                  title: const Text('Не удалось загрузить ленту'),
                  subtitle: const Text(
                    'Проверьте соединение и попробуйте снова.',
                  ),
                  trailing: onFeedRetry == null
                      ? null
                      : TextButton(
                          onPressed: onFeedRetry,
                          child: const Text('Повторить'),
                        ),
                ),
              ),
            ] else if (feedCards.isNotEmpty) ...[
              const SizedBox(height: sectionGap),
              StudentProfileFeedCarousel(
                cards: feedCards,
                selectedId: selectedFeedId,
                onTap: (card) => onFeedTap?.call(card),
                onVisibleCard: onFeedVisible,
              ),
            ],
            if (showStudySection) ...[
              const SizedBox(height: sectionGap),
              const _SectionTitle('Учёба'),
              const SizedBox(height: sectionGap),
              if (showDiary)
                _StudyBanner(
                  title: 'Мой дневник',
                  subtitle: guest
                      ? 'Заметки и конспекты на этом устройстве'
                      : 'Записи, конспекты и файлы по предметам текущего семестра',
                  icon: Icons.menu_book_outlined,
                  iconColor: _accent,
                  onTap: onDiaryTap,
                ),
              if (showDiary) const SizedBox(height: sectionGap),
              _StudyBanner(
                title: 'Карта СПБГАСУ',
                icon: Icons.map_outlined,
                iconColor: const Color(0xFF2F9D84),
                onTap: onMapTap,
                compact: true,
              ),
            ],
            const SizedBox(height: sectionGap),
            OutlinedButton.icon(
              onPressed: onReviewsTap,
              icon: const Icon(Icons.rate_review_outlined),
              label: const Text('Мои отзывы'),
            ),
            if (footer != null) ...[
              const SizedBox(height: sectionGap),
              footer!
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileFeedDetailView extends StatelessWidget {
  const _ProfileFeedDetailView({
    required this.card,
    this.onBack,
  });

  final ManagedProfileFeedCard card;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payload = card.payload;
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Назад',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    payload.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                SizedBox(
                  height: 180,
                  child: StudentProfileFeedCard(
                    payload: payload,
                    showDemoBadge: card.showDemoBadge,
                    imageBytes: card.imageBytes,
                    imageLoading: card.imageLoading,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  payload.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                if (payload.subtitle.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    payload.subtitle,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (payload.ctaLabel.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    payload.ctaLabel,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: StudentProfileScreenPreview._accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftHeader extends StatelessWidget {
  const _SoftHeader({
    this.guest = false,
    required this.displayName,
    required this.groupLabel,
    this.universityLabel,
    this.statusLabel,
    this.avatarBytes,
    this.avatarUrl,
    this.avatarImage,
  });

  final bool guest;
  final String displayName;
  final String groupLabel;
  final String? universityLabel;
  final String? statusLabel;
  final Uint8List? avatarBytes;
  final String? avatarUrl;
  final ImageProvider? avatarImage;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final uni = universityLabel?.trim() ?? '';
    final group = groupLabel.trim();
    final subtitle = [
      if (uni.isNotEmpty) uni,
      if (group.isNotEmpty) 'группа $group',
    ].join(', ');

    ImageProvider? avatarProvider = avatarImage;
    if (avatarBytes != null && avatarBytes!.isNotEmpty) {
      avatarProvider = MemoryImage(avatarBytes!);
    } else if (avatarProvider == null) {
      final url = avatarUrl?.trim();
      if (url != null && url.isNotEmpty) {
        avatarProvider = NetworkImage(url);
      }
    }

    return Column(
      children: [
        CircleAvatar(
          radius: 44,
          backgroundColor: StudentProfileScreenPreview._lavender,
          backgroundImage: avatarProvider,
          child: avatarProvider == null
              ? const Icon(Icons.person, size: 44, color: Color(0xFF6B7280))
              : null,
        ),
        const SizedBox(height: 12),
        Text(
          displayName.isEmpty ? 'Без имени' : displayName,
          style: text.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          guest
              ? 'Без аккаунта'
              : subtitle.isEmpty
                  ? 'Данные профиля не заполнены'
                  : subtitle,
          style: text.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
          textAlign: TextAlign.center,
        ),
        if (statusLabel != null && statusLabel!.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            statusLabel!.trim(),
            style: text.bodyLarge,
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

class _ActionsRow extends StatelessWidget {
  const _ActionsRow({
    this.messagesBadge = 0,
    this.friendsBadge = 0,
    this.onMessagesTap,
    this.onFriendsTap,
  });

  final int messagesBadge;
  final int friendsBadge;
  final VoidCallback? onMessagesTap;
  final VoidCallback? onFriendsTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onMessagesTap ?? () {},
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Сообщения'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  backgroundColor: Color.alphaBlend(
                      const Color(0xFF7C63D8).withValues(alpha: 0.06),
                      Theme.of(context).colorScheme.surface),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onFriendsTap ?? () {},
                icon: const Icon(Icons.group_outlined, size: 18),
                label: const Text('Друзья'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor:
                      Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF8BD9C4)
                          : const Color(0xFF2F6B5E),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  backgroundColor: Color.alphaBlend(
                      const Color(0xFF2F9D84).withValues(alpha: 0.06),
                      Theme.of(context).colorScheme.surface),
                ),
              ),
            ),
          ],
        ),
        if (messagesBadge > 0)
          Positioned(
            left: 0,
            top: -10,
            child: _EdgeBadge(
              text: messagesBadge > 99 ? '99+' : messagesBadge.toString(),
            ),
          ),
        if (friendsBadge > 0)
          Positioned(
            right: 0,
            top: -10,
            child: _EdgeBadge(
              text: friendsBadge > 9 ? '9+' : friendsBadge.toString(),
            ),
          ),
      ],
    );
  }
}

class _EdgeBadge extends StatelessWidget {
  const _EdgeBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
    );
  }
}

class _StudyBanner extends StatelessWidget {
  const _StudyBanner({
    required this.title,
    required this.icon,
    required this.iconColor,
    this.subtitle,
    this.onTap,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final Color iconColor;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          height: compact &&
                  MediaQuery.sizeOf(context).width >= 360 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 16
              ? 64
              : null,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Theme.of(context).colorScheme.surface,
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 24, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF6B7280)),
            ],
          ),
        ),
      ),
    );
  }
}
