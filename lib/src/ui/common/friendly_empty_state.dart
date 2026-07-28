import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Compact empty state: Lottie (or static fallback) above title, subtitle below.
class FriendlyEmptyState extends StatelessWidget {
  const FriendlyEmptyState({
    super.key,
    required this.title,
    this.subtitle,
    this.lottieAsset,
    this.fallbackIcon = Icons.inbox_outlined,
    this.animationHeight = 140,
    this.action,
  });

  final String title;
  final String? subtitle;
  final String? lottieAsset;
  final IconData fallbackIcon;
  final double animationHeight;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: animationHeight,
              width: animationHeight,
              child: _AnimationSlot(
                asset: lottieAsset,
                fallbackIcon: fallbackIcon,
                reduceMotion: reduceMotion,
                iconColor: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
              ),
            ),
            if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.25,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _AnimationSlot extends StatelessWidget {
  const _AnimationSlot({
    required this.asset,
    required this.fallbackIcon,
    required this.reduceMotion,
    required this.iconColor,
  });

  final String? asset;
  final IconData fallbackIcon;
  final bool reduceMotion;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    if (asset == null || asset!.isEmpty) {
      return _IconFallback(icon: fallbackIcon, color: iconColor);
    }

    return Lottie.asset(
      asset!,
      fit: BoxFit.contain,
      repeat: !reduceMotion,
      // First frame only when reduce-motion / disableAnimations is on.
      animate: !reduceMotion,
      frameBuilder: (context, child, composition) {
        if (composition == null) {
          return _IconFallback(icon: fallbackIcon, color: iconColor);
        }
        return child;
      },
      errorBuilder: (context, error, stackTrace) {
        return _IconFallback(icon: fallbackIcon, color: iconColor);
      },
    );
  }
}

class _IconFallback extends StatelessWidget {
  const _IconFallback({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(icon, size: 56, color: color),
    );
  }
}
