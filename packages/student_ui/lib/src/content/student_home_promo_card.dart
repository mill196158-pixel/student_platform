import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'content_icon_resolver.dart';
import 'content_models.dart';

/// Shared Home promo renderer for Mobile and Admin Preview.
///
/// Approved template: `home_promo_v1`. Never pass raw JSON into this widget.
class StudentHomePromoCard extends StatelessWidget {
  const StudentHomePromoCard({
    super.key,
    required this.payload,
    this.onTap,
    this.onDismiss,
    this.showDemoBadge = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.imageBytes,
    this.imageLoading = false,
  });

  final HomePromoPayload payload;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;
  final bool showDemoBadge;
  final EdgeInsetsGeometry padding;
  final Uint8List? imageBytes;
  final bool imageLoading;

  /// Convenience constructor for the historic demo card.
  factory StudentHomePromoCard.demoStuckWithAssignment({
    Key? key,
    VoidCallback? onTap,
  }) {
    return StudentHomePromoCard(
      key: key,
      payload: HomePromoPayload.demoStuckWithAssignment,
      onTap: onTap,
      showDemoBadge: true,
    );
  }

  bool get _hasImageBytes => imageBytes != null && imageBytes!.isNotEmpty;

  String get _variant {
    final raw = effectiveContentCardVariant(payload.cardVariant);
    if (contentCardVariantUsesImage(raw) && !_hasImageBytes && !imageLoading) {
      return 'gradient_text';
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Semantics(
        button: onTap != null,
        label: payload.title,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: _buildVariant(context),
        ),
      ),
    );
  }

  Widget _buildVariant(BuildContext context) {
    return switch (_variant) {
      'image_full' => _ImageFullLayout(card: this),
      'image_overlay' => _ImageOverlayLayout(card: this),
      'image_top_text' => _ImageTopTextLayout(card: this),
      'compact_icon' => _CompactIconLayout(card: this),
      'accent_info' => _AccentInfoLayout(card: this),
      'no_image' => _NoImageLayout(card: this),
      _ => _GradientTextLayout(card: this),
    };
  }
}

class _PromoTheme {
  _PromoTheme(BuildContext context, HomePromoPayload payload)
      : theme = Theme.of(context),
        isDark = Theme.of(context).brightness == Brightness.dark,
        titleColor = Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : const Color(0xFF111827),
        bodyColor = Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.72)
            : const Color(0xFF64748B),
        accent = Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFFA78BFA)
            : const Color(0xFF7C63D8),
        gradient = contentPayloadGradient(
          colors: payload.gradientColors,
          angle: payload.gradientAngle,
        ),
        icon = resolveContentIcon(
          iconKey: payload.iconKey,
          iconAssetId: payload.iconAssetId,
        );

  final ThemeData theme;
  final bool isDark;
  final Color titleColor;
  final Color bodyColor;
  final Color accent;
  final LinearGradient gradient;
  final ContentIconResolved icon;
}

class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.card,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.decoration,
    this.clipBehavior = Clip.none,
    this.minHeight,
  });

  final StudentHomePromoCard card;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final BoxDecoration? decoration;
  final Clip clipBehavior;
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    final baseDecoration = BoxDecoration(
      gradient: t.isDark ? null : t.gradient,
      color: t.isDark ? const Color(0xFF182331) : null,
      borderRadius: BorderRadius.circular(28),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: t.isDark ? 0.22 : 0.05),
          blurRadius: 22,
          offset: const Offset(0, 10),
        ),
      ],
    );

    return Container(
      constraints:
          minHeight != null ? BoxConstraints(minHeight: minHeight!) : null,
      clipBehavior: clipBehavior,
      padding: padding,
      decoration: decoration ?? baseDecoration,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (card.payload.dismissible && card.onDismiss != null)
            Positioned(
              top: -4,
              right: -4,
              child: IconButton(
                tooltip: 'Скрыть',
                onPressed: card.onDismiss,
                icon: Icon(
                  Icons.close_rounded,
                  size: 20,
                  color: t.bodyColor,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge({required this.accent, required this.theme});

  final Color accent;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Пример',
      style: theme.textTheme.labelMedium?.copyWith(
        color: accent,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _CtaButton extends StatelessWidget {
  const _CtaButton({
    required this.label,
    required this.onTap,
    required this.accent,
    this.compact = false,
    this.lightOnDark = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Color accent;
  final bool compact;
  final bool lightOnDark;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: lightOnDark ? Colors.white : accent,
            ),
      );
    }
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: lightOnDark ? Colors.white : accent,
        foregroundColor: lightOnDark ? accent : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _PromoImagePlane extends StatelessWidget {
  const _PromoImagePlane({
    required this.card,
    required this.colors,
    this.borderRadius,
    this.overlayOpacity = 0,
    this.height,
  });

  final StudentHomePromoCard card;
  final List<Color> colors;
  final BorderRadius? borderRadius;
  final double overlayOpacity;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.zero;
    final hasBytes = card._hasImageBytes;

    if (card.imageLoading && !hasBytes) {
      return _ImageSkeleton(
        height: height ?? 160,
        borderRadius: radius,
        colors: colors,
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        height: height,
        width: height == null ? double.infinity : null,
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
      ),
    );
  }
}

class _ImageSkeleton extends StatelessWidget {
  const _ImageSkeleton({
    required this.height,
    required this.borderRadius,
    required this.colors,
  });

  final double height;
  final BorderRadius borderRadius;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final base = colors.isNotEmpty ? colors.first : const Color(0xFFE9EAF1);
    final end = colors.length > 1 ? colors.last : const Color(0xFFD7D9E4);
    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox(
        height: height,
        width: double.infinity,
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
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }
}

class _GradientTextLayout extends StatelessWidget {
  const _GradientTextLayout({required this.card});

  final StudentHomePromoCard card;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    return _CardShell(
      card: card,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!t.icon.isNone && t.icon.iconData != null)
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: t.isDark ? 0.18 : 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(t.icon.iconData, color: t.accent),
            ),
          if (!t.icon.isNone && t.icon.iconData != null)
            const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (card.showDemoBadge) ...[
                  _DemoBadge(accent: t.accent, theme: t.theme),
                  const SizedBox(height: 6),
                ],
                Text(
                  card.payload.title,
                  style: t.theme.textTheme.titleMedium?.copyWith(
                    color: t.titleColor,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  card.payload.subtitle,
                  style: t.theme.textTheme.bodyMedium?.copyWith(
                    color: t.bodyColor,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                _CtaButton(
                  label: card.payload.ctaLabel,
                  onTap: card.onTap,
                  accent: t.accent,
                ),
              ],
            ),
          ),
          if (card.payload.dismissible && card.onDismiss != null)
            const SizedBox(width: 28),
        ],
      ),
    );
  }
}

class _ImageFullLayout extends StatelessWidget {
  const _ImageFullLayout({required this.card});

  final StudentHomePromoCard card;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    return _CardShell(
      card: card,
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      minHeight: card.imageLoading && !card._hasImageBytes ? 160 : null,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.isDark ? 0.22 : 0.05),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PromoImagePlane(
            card: card,
            colors: card.payload.gradientColors,
            borderRadius: BorderRadius.circular(28),
            height: card.imageLoading && !card._hasImageBytes ? 160 : null,
          ),
          if (card.payload.title.isNotEmpty)
            Positioned(
              left: 16,
              bottom: 12,
              right:
                  card.payload.dismissible && card.onDismiss != null ? 40 : 16,
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

class _ImageOverlayLayout extends StatelessWidget {
  const _ImageOverlayLayout({required this.card});

  final StudentHomePromoCard card;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    return _CardShell(
      card: card,
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      minHeight: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.isDark ? 0.22 : 0.05),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _PromoImagePlane(
            card: card,
            colors: card.payload.gradientColors,
            borderRadius: BorderRadius.circular(28),
            overlayOpacity: 0.45,
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (card.showDemoBadge) ...[
                  _DemoBadge(accent: Colors.white70, theme: t.theme),
                  const SizedBox(height: 6),
                ],
                Text(
                  card.payload.title,
                  style: t.theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  card.payload.subtitle,
                  style: t.theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.88),
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                _CtaButton(
                  label: card.payload.ctaLabel,
                  onTap: card.onTap,
                  accent: t.accent,
                  lightOnDark: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageTopTextLayout extends StatelessWidget {
  const _ImageTopTextLayout({required this.card});

  final StudentHomePromoCard card;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    return _CardShell(
      card: card,
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF182331) : Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.isDark ? 0.22 : 0.05),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PromoImagePlane(
            card: card,
            colors: card.payload.gradientColors,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            height: card.imageLoading && !card._hasImageBytes ? 140 : 140,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (card.showDemoBadge) ...[
                  _DemoBadge(accent: t.accent, theme: t.theme),
                  const SizedBox(height: 6),
                ],
                Text(
                  card.payload.title,
                  style: t.theme.textTheme.titleMedium?.copyWith(
                    color: t.titleColor,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  card.payload.subtitle,
                  style: t.theme.textTheme.bodyMedium?.copyWith(
                    color: t.bodyColor,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                _CtaButton(
                  label: card.payload.ctaLabel,
                  onTap: card.onTap,
                  accent: t.accent,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactIconLayout extends StatelessWidget {
  const _CompactIconLayout({required this.card});

  final StudentHomePromoCard card;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    return _CardShell(
      card: card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          if (!t.icon.isNone && t.icon.iconData != null)
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: t.accent.withValues(alpha: t.isDark ? 0.18 : 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(t.icon.iconData, size: 22, color: t.accent),
            ),
          if (!t.icon.isNone && t.icon.iconData != null)
            const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (card.showDemoBadge) ...[
                  _DemoBadge(accent: t.accent, theme: t.theme),
                  const SizedBox(height: 4),
                ],
                Text(
                  card.payload.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.theme.textTheme.titleSmall?.copyWith(
                    color: t.titleColor,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _CtaButton(
            label: card.payload.ctaLabel,
            onTap: card.onTap,
            accent: t.accent,
            compact: true,
          ),
          if (card.payload.dismissible && card.onDismiss != null)
            const SizedBox(width: 24),
        ],
      ),
    );
  }
}

class _AccentInfoLayout extends StatelessWidget {
  const _AccentInfoLayout({required this.card});

  final StudentHomePromoCard card;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    final infoBg = t.isDark ? const Color(0xFF1E2A3D) : const Color(0xFFE8F1FF);
    return _CardShell(
      card: card,
      decoration: BoxDecoration(
        color: infoBg,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: t.accent.withValues(alpha: 0.45),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.isDark ? 0.22 : 0.05),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            t.icon.isNone ? Icons.info_outline_rounded : t.icon.iconData,
            color: t.accent,
            size: 28,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (card.showDemoBadge) ...[
                  _DemoBadge(accent: t.accent, theme: t.theme),
                  const SizedBox(height: 6),
                ],
                Text(
                  card.payload.title,
                  style: t.theme.textTheme.titleMedium?.copyWith(
                    color: t.titleColor,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  card.payload.subtitle,
                  style: t.theme.textTheme.bodyMedium?.copyWith(
                    color: t.bodyColor,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                _CtaButton(
                  label: card.payload.ctaLabel,
                  onTap: card.onTap,
                  accent: t.accent,
                ),
              ],
            ),
          ),
          if (card.payload.dismissible && card.onDismiss != null)
            const SizedBox(width: 28),
        ],
      ),
    );
  }
}

class _NoImageLayout extends StatelessWidget {
  const _NoImageLayout({required this.card});

  final StudentHomePromoCard card;

  @override
  Widget build(BuildContext context) {
    final t = _PromoTheme(context, card.payload);
    return _CardShell(
      card: card,
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF182331) : const Color(0xFFF4F5FA),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: t.isDark ? 0.22 : 0.05),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (card.showDemoBadge) ...[
            _DemoBadge(accent: t.accent, theme: t.theme),
            const SizedBox(height: 6),
          ],
          Text(
            card.payload.title,
            style: t.theme.textTheme.titleMedium?.copyWith(
              color: t.titleColor,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            card.payload.subtitle,
            style: t.theme.textTheme.bodyMedium?.copyWith(
              color: t.bodyColor,
              height: 1.35,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          _CtaButton(
            label: card.payload.ctaLabel,
            onTap: card.onTap,
            accent: t.accent,
          ),
        ],
      ),
    );
  }
}
