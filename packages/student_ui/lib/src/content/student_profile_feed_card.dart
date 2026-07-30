import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'content_icon_resolver.dart';
import 'content_models.dart';

const _kDefaultFeedGradient = [Color(0xFFDCD0FA), Color(0xFFC9B8F3)];

/// Shared Profile feed card renderer (Mobile + Admin Preview).
///
/// Template: `profile_feed_card_v1`. Never pass raw JSON.
class StudentProfileFeedCard extends StatelessWidget {
  const StudentProfileFeedCard({
    super.key,
    required this.payload,
    this.onTap,
    this.showDemoBadge = false,
    this.gradientColors,
    this.imageBytes,
    this.imageLoading = false,
  });

  final ProfileFeedPayload payload;
  final VoidCallback? onTap;
  final bool showDemoBadge;

  /// Optional override; when null, [payload.gradientColors] is used.
  final List<Color>? gradientColors;
  final Uint8List? imageBytes;
  final bool imageLoading;

  bool get _hasImageBytes => imageBytes != null && imageBytes!.isNotEmpty;

  List<Color> get _resolvedGradientColors {
    final fromPayload = payload.gradientColors;
    if (fromPayload != null && fromPayload.length >= 2) return fromPayload;
    if (gradientColors != null && gradientColors!.length >= 2) {
      return gradientColors!;
    }
    return _kDefaultFeedGradient;
  }

  String get _variant {
    final raw = effectiveContentCardVariant(payload.cardVariant);
    if (contentCardVariantUsesImage(raw) && !_hasImageBytes && !imageLoading) {
      return 'gradient_text';
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: _buildVariant(context),
      ),
    );
  }

  Widget _buildVariant(BuildContext context) {
    return switch (_variant) {
      'image_full' => _FeedImageFullLayout(card: this),
      'image_overlay' => _FeedImageOverlayLayout(card: this),
      'image_top_text' => _FeedImageTopTextLayout(card: this),
      'compact_icon' => _FeedCompactIconLayout(card: this),
      'accent_info' => _FeedAccentInfoLayout(card: this),
      'no_image' => _FeedNoImageLayout(card: this),
      _ => _FeedGradientTextLayout(card: this),
    };
  }
}

class _FeedTheme {
  _FeedTheme(BuildContext context, StudentProfileFeedCard card)
      : theme = Theme.of(context),
        colors = card._resolvedGradientColors,
        gradient = contentPayloadGradient(
          colors: card._resolvedGradientColors,
          angle: card.payload.gradientAngle,
        ),
        titleColor = const Color(0xFF111827),
        bodyColor = const Color(0xFF374151),
        accent = const Color(0xFF5B21B6),
        icon = resolveContentIcon(
          iconKey: card.payload.iconKey,
          iconAssetId: card.payload.iconAssetId,
        );

  final ThemeData theme;
  final List<Color> colors;
  final LinearGradient gradient;
  final Color titleColor;
  final Color bodyColor;
  final Color accent;
  final ContentIconResolved icon;
}

class _FeedCardShell extends StatelessWidget {
  const _FeedCardShell({
    required this.card,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.decoration,
    this.clipBehavior = Clip.none,
  });

  final StudentProfileFeedCard card;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BoxDecoration? decoration;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6),
      clipBehavior: clipBehavior,
      padding: padding,
      decoration: decoration ??
          BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: t.gradient,
            boxShadow: [
              BoxShadow(
                color: t.colors.last.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
      child: child,
    );
  }
}

class _FeedDemoBadge extends StatelessWidget {
  const _FeedDemoBadge({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Пример',
      style: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w800,
        color: const Color(0xFF4C1D95),
      ),
    );
  }
}

class _FeedImagePlane extends StatelessWidget {
  const _FeedImagePlane({
    required this.card,
    required this.colors,
    this.borderRadius,
    this.overlayOpacity = 0,
    this.flex,
    this.height,
  });

  final StudentProfileFeedCard card;
  final List<Color> colors;
  final BorderRadius? borderRadius;
  final double overlayOpacity;
  final int? flex;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.zero;
    final hasBytes = card._hasImageBytes;

    if (card.imageLoading && !hasBytes) {
      return _FeedImageSkeleton(
        height: height ?? 80,
        borderRadius: radius,
        colors: colors,
        flex: flex,
      );
    }

    final image = ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasBytes)
            Image.memory(
              card.imageBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: contentPayloadGradient(
                  colors: colors,
                  angle: card.payload.gradientAngle,
                ),
              ),
            ),
          if (overlayOpacity > 0)
            ColoredBox(color: Colors.black.withValues(alpha: overlayOpacity)),
        ],
      ),
    );

    if (flex != null) {
      return Expanded(flex: flex!, child: image);
    }
    return SizedBox(height: height, child: image);
  }
}

class _FeedImageSkeleton extends StatelessWidget {
  const _FeedImageSkeleton({
    required this.height,
    required this.borderRadius,
    required this.colors,
    this.flex,
  });

  final double height;
  final BorderRadius borderRadius;
  final List<Color> colors;
  final int? flex;

  @override
  Widget build(BuildContext context) {
    final base = colors.isNotEmpty ? colors.first : const Color(0xFFE9EAF1);
    final end = colors.length > 1 ? colors.last : const Color(0xFFD7D9E4);
    final skeleton = ClipRRect(
      borderRadius: borderRadius,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(base, end, 0.35)!,
              Color.lerp(end, base, 0.45)!,
            ],
          ),
        ),
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
    if (flex != null) return Expanded(flex: flex!, child: skeleton);
    return SizedBox(height: height, child: skeleton);
  }
}

class _FeedGradientTextLayout extends StatelessWidget {
  const _FeedGradientTextLayout({required this.card});

  final StudentProfileFeedCard card;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    return _FeedCardShell(
      card: card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (card.showDemoBadge) _FeedDemoBadge(theme: t.theme),
          if (!t.icon.isNone && t.icon.iconData != null) ...[
            Icon(t.icon.iconData, color: t.accent, size: 22),
            const SizedBox(height: 8),
          ],
          const Spacer(),
          Text(
            card.payload.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: t.titleColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            card.payload.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: t.bodyColor,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            card.payload.ctaLabel,
            style: t.theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: t.accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedImageFullLayout extends StatelessWidget {
  const _FeedImageFullLayout({required this.card});

  final StudentProfileFeedCard card;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    return _FeedCardShell(
      card: card,
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: t.colors.last.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _FeedImagePlane(
            card: card,
            colors: t.colors,
            borderRadius: BorderRadius.circular(20),
          ),
          if (card.payload.title.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 10,
              right: 12,
              child: Text(
                card.payload.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  shadows: const [
                    Shadow(color: Colors.black54, blurRadius: 6),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FeedImageOverlayLayout extends StatelessWidget {
  const _FeedImageOverlayLayout({required this.card});

  final StudentProfileFeedCard card;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    final overlay = payloadOverlayOpacity(card.payload.overlayOpacity);
    return _FeedCardShell(
      card: card,
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: t.colors.last.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _FeedImagePlane(
            card: card,
            colors: t.colors,
            borderRadius: BorderRadius.circular(20),
            overlayOpacity: overlay,
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (card.showDemoBadge) ...[
                  Text(
                    'Пример',
                    style: t.theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.white70,
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  card.payload.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  card.payload.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.88),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  card.payload.ctaLabel,
                  style: t.theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

double payloadOverlayOpacity(double? raw) {
  if (raw == null) return 0.45;
  return raw.clamp(0.0, 1.0);
}

class _FeedImageTopTextLayout extends StatelessWidget {
  const _FeedImageTopTextLayout({required this.card});

  final StudentProfileFeedCard card;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    return _FeedCardShell(
      card: card,
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: t.colors.last.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FeedImagePlane(
            card: card,
            colors: t.colors,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            height: card.imageLoading && !card._hasImageBytes ? 80 : 80,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (card.showDemoBadge) _FeedDemoBadge(theme: t.theme),
                  Text(
                    card.payload.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: t.titleColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    card.payload.ctaLabel,
                    style: t.theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: t.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedCompactIconLayout extends StatelessWidget {
  const _FeedCompactIconLayout({required this.card});

  final StudentProfileFeedCard card;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    return _FeedCardShell(
      card: card,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          if (!t.icon.isNone && t.icon.iconData != null)
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(t.icon.iconData, size: 20, color: t.accent),
            ),
          if (!t.icon.isNone && t.icon.iconData != null)
            const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (card.showDemoBadge) _FeedDemoBadge(theme: t.theme),
                Text(
                  card.payload.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: t.titleColor,
                  ),
                ),
              ],
            ),
          ),
          Text(
            card.payload.ctaLabel,
            style: t.theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: t.accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedAccentInfoLayout extends StatelessWidget {
  const _FeedAccentInfoLayout({required this.card});

  final StudentProfileFeedCard card;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    return _FeedCardShell(
      card: card,
      decoration: BoxDecoration(
        color: const Color(0xFFE8F1FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: t.accent.withValues(alpha: 0.45),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: t.colors.last.withValues(alpha: 0.2),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (card.showDemoBadge) _FeedDemoBadge(theme: t.theme),
          Icon(
            t.icon.isNone ? Icons.info_outline_rounded : t.icon.iconData,
            color: t.accent,
            size: 24,
          ),
          const Spacer(),
          Text(
            card.payload.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: t.titleColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            card.payload.ctaLabel,
            style: t.theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: t.accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeedNoImageLayout extends StatelessWidget {
  const _FeedNoImageLayout({required this.card});

  final StudentProfileFeedCard card;

  @override
  Widget build(BuildContext context) {
    final t = _FeedTheme(context, card);
    return _FeedCardShell(
      card: card,
      decoration: BoxDecoration(
        color: const Color(0xFFF4F5FA),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (card.showDemoBadge) _FeedDemoBadge(theme: t.theme),
          const Spacer(),
          Text(
            card.payload.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w900,
              color: t.titleColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            card.payload.subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: t.bodyColor,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            card.payload.ctaLabel,
            style: t.theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: t.accent,
            ),
          ),
        ],
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
    this.selectedId,
  });

  final List<ManagedProfileFeedCard> cards;
  final ValueChanged<ManagedProfileFeedCard> onTap;

  /// Fired when a page becomes the primary visible card (incl. first page).
  final ValueChanged<ManagedProfileFeedCard>? onVisibleCard;

  /// When set, animates (or jumps) to the card with this stable [ManagedProfileFeedCard.id].
  final String? selectedId;

  @override
  State<StudentProfileFeedCarousel> createState() =>
      _StudentProfileFeedCarouselState();
}

class _StudentProfileFeedCarouselState
    extends State<StudentProfileFeedCarousel> {
  late final PageController _controller;
  int _pageIndex = 0;
  String? _lastVisibleId;
  bool _suppressNextVisibleNotify = false;

  int _indexForId(String id) =>
      widget.cards.indexWhere((card) => card.id == id);

  int _initialPageIndex() {
    if (widget.cards.isEmpty) return 0;
    final selectedId = widget.selectedId;
    if (selectedId != null) {
      final index = _indexForId(selectedId);
      if (index >= 0) return index;
    }
    return 0;
  }

  String? get _currentCardId {
    if (widget.cards.isEmpty) return null;
    final index = _pageIndex.clamp(0, widget.cards.length - 1);
    return widget.cards[index].id;
  }

  void _clampPage({bool suppressNotify = false}) {
    if (widget.cards.isEmpty) {
      _pageIndex = 0;
      _lastVisibleId = null;
      return;
    }
    if (_pageIndex >= widget.cards.length) {
      _pageIndex = widget.cards.length - 1;
      if (suppressNotify) _suppressNextVisibleNotify = true;
      if (_controller.hasClients) {
        _controller.jumpToPage(_pageIndex);
      }
    }
  }

  void _goToIndex(int index, {required bool animate}) {
    if (index < 0 || index >= widget.cards.length) return;
    if (index == _pageIndex && widget.cards[index].id == _currentCardId) {
      return;
    }
    _suppressNextVisibleNotify = true;
    _pageIndex = index;
    _lastVisibleId = widget.cards[index].id;
    if (!_controller.hasClients) return;
    if (animate) {
      unawaited(
        _controller.animateToPage(
          index,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        ),
      );
    } else {
      _controller.jumpToPage(index);
    }
  }

  void _syncToSelectedId(String? selectedId, {required bool animate}) {
    if (selectedId == null) {
      _clampPage(suppressNotify: true);
      return;
    }
    final index = _indexForId(selectedId);
    if (index < 0) {
      _clampPage(suppressNotify: true);
      return;
    }
    if (selectedId == _currentCardId) return;
    _goToIndex(index, animate: animate);
  }

  void _notifyVisible({bool force = false}) {
    if (_suppressNextVisibleNotify) {
      _suppressNextVisibleNotify = false;
      if (widget.cards.isNotEmpty) {
        final index = _pageIndex.clamp(0, widget.cards.length - 1);
        _lastVisibleId = widget.cards[index].id;
      }
      return;
    }
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
    _pageIndex = _initialPageIndex();
    _controller = PageController(
      viewportFraction: 0.92,
      initialPage: _pageIndex,
    );
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

    final selectedChanged = widget.selectedId != oldWidget.selectedId;
    if (selectedChanged ||
        (widget.selectedId != null &&
            widget.selectedId != _currentCardId &&
            _indexForId(widget.selectedId!) >= 0)) {
      _syncToSelectedId(
        widget.selectedId,
        animate: _controller.hasClients && selectedChanged,
      );
    } else if (widget.selectedId != null &&
        _indexForId(widget.selectedId!) < 0) {
      _clampPage(suppressNotify: true);
    } else if (_pageIndex >= widget.cards.length) {
      _clampPage(suppressNotify: true);
    }

    final nextId =
        widget.cards[_pageIndex.clamp(0, widget.cards.length - 1)].id;
    final oldId =
        oldWidget.cards.isEmpty || _pageIndex >= oldWidget.cards.length
            ? null
            : oldWidget.cards[_pageIndex].id;
    if (!_suppressNextVisibleNotify &&
        (nextId != oldId || nextId != _lastVisibleId)) {
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
            onTap: () => widget.onTap(card),
            imageBytes: card.imageBytes,
            imageLoading: card.imageLoading,
          );
        },
      ),
    );
  }
}
