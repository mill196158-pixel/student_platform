import 'package:flutter/material.dart';

import 'content_models.dart';

/// Shared Home promo renderer for Mobile and Admin Preview.
///
/// Approved template: `home_promo_v1`. Never pass raw JSON into this widget.
class StudentHomePromoCard extends StatelessWidget {
  const StudentHomePromoCard({
    super.key,
    required this.payload,
    this.onTap,
    this.showDemoBadge = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  final HomePromoPayload payload;
  final VoidCallback? onTap;
  final bool showDemoBadge;
  final EdgeInsetsGeometry padding;

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF111827);
    final bodyColor = isDark
        ? Colors.white.withValues(alpha: 0.72)
        : const Color(0xFF64748B);
    final accent = isDark ? const Color(0xFFA78BFA) : const Color(0xFF7C63D8);

    final lightGradient = payload.gradientColors.length >= 2
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: payload.gradientColors,
          )
        : const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFFBFF), Color(0xFFF3EEF9)],
          );

    return Padding(
      padding: padding,
      child: Semantics(
        button: onTap != null,
        label: payload.title,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: isDark ? null : lightGradient,
              color: isDark ? const Color(0xFF182331) : null,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.22 : 0.05),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.18 : 0.12),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(payload.iconData, color: accent),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showDemoBadge) ...[
                        Text(
                          'Пример',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Text(
                        payload.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: titleColor,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        payload.subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: bodyColor,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      FilledButton(
                        onPressed: onTap,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: Text(
                          payload.ctaLabel,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
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
