import 'package:flutter/material.dart';

import 'content_models.dart';

/// Shared Profile feed card renderer (Mobile + Admin Preview).
///
/// Template: `profile_feed_card_v1`. Never pass raw JSON.
class StudentProfileFeedCard extends StatelessWidget {
  const StudentProfileFeedCard({
    super.key,
    required this.payload,
    this.onTap,
    this.showDemoBadge = false,
    this.gradientColors = const [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
  });

  final ProfileFeedPayload payload;
  final VoidCallback? onTap;
  final bool showDemoBadge;
  final List<Color> gradientColors;

  @override
  Widget build(BuildContext context) {
    final colors = gradientColors.length >= 2
        ? gradientColors
        : const [Color(0xFFDCD0FA), Color(0xFFC9B8F3)];
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              colors: colors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: colors.last.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showDemoBadge)
                  Text(
                    'Пример',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF4C1D95),
                        ),
                  ),
                const Spacer(),
                Text(
                  payload.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF111827),
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  payload.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF374151),
                      ),
                ),
                const SizedBox(height: 10),
                Text(
                  payload.ctaLabel,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFF5B21B6),
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal list of profile feed cards (shared Mobile/Admin).
class StudentProfileFeedCarousel extends StatefulWidget {
  const StudentProfileFeedCarousel({
    super.key,
    required this.cards,
    required this.onTap,
    this.onVisibleCard,
  });

  final List<ManagedProfileFeedCard> cards;
  final ValueChanged<ManagedProfileFeedCard> onTap;

  /// Fired when a page becomes the primary visible card (incl. first page).
  final ValueChanged<ManagedProfileFeedCard>? onVisibleCard;

  @override
  State<StudentProfileFeedCarousel> createState() =>
      _StudentProfileFeedCarouselState();
}

class _StudentProfileFeedCarouselState
    extends State<StudentProfileFeedCarousel> {
  late final PageController _controller =
      PageController(viewportFraction: 0.92);
  int _pageIndex = 0;
  String? _lastVisibleId;

  static const _gradients = <List<Color>>[
    [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
    [Color(0xFFC5EFE5), Color(0xFFAEE3D8)],
    [Color(0xFFFFE5B9), Color(0xFFDCD0FA)],
  ];

  void _notifyVisible({bool force = false}) {
    if (widget.cards.isEmpty) {
      _lastVisibleId = null;
      return;
    }
    final index = _pageIndex.clamp(0, widget.cards.length - 1);
    if (index != _pageIndex) _pageIndex = index;
    final card = widget.cards[index];
    if (!force && card.id == _lastVisibleId) return;
    _lastVisibleId = card.id;
    widget.onVisibleCard?.call(card);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyVisible(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant StudentProfileFeedCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cards.isEmpty) {
      _lastVisibleId = null;
      return;
    }
    if (_pageIndex >= widget.cards.length) {
      _pageIndex = widget.cards.length - 1;
      if (_controller.hasClients) {
        _controller.jumpToPage(_pageIndex);
      }
    }
    final nextId = widget.cards[_pageIndex].id;
    final oldId =
        oldWidget.cards.isEmpty || _pageIndex >= oldWidget.cards.length
            ? null
            : oldWidget.cards[_pageIndex].id;
    if (nextId != oldId || nextId != _lastVisibleId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _notifyVisible(force: true);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.cards.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 160,
      child: PageView.builder(
        controller: _controller,
        itemCount: widget.cards.length,
        onPageChanged: (index) {
          _pageIndex = index;
          _notifyVisible(force: true);
        },
        itemBuilder: (context, index) {
          final card = widget.cards[index];
          return StudentProfileFeedCard(
            payload: card.payload,
            showDemoBadge: card.showDemoBadge,
            gradientColors: _gradients[index % _gradients.length],
            onTap: () => widget.onTap(card),
          );
        },
      ),
    );
  }
}
