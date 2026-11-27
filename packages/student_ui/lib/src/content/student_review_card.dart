import 'package:flutter/material.dart';

import 'review_models.dart';

/// Shared review summary card (Mobile + Admin Preview).
///
/// Never pass raw JSON — only [StudentReviewCardPayload].
class StudentReviewCard extends StatelessWidget {
  const StudentReviewCard({
    super.key,
    required this.payload,
    this.showDemoBadge = false,
    this.onTap,
    this.inProfileList = false,
  });

  final StudentReviewCardPayload payload;
  final bool showDemoBadge;
  final VoidCallback? onTap;
  final bool inProfileList;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = payload.moderationStatus;
    final dark = inProfileList && theme.brightness == Brightness.dark;
    final statusColor = switch (status) {
      ReviewModerationStatus.pending =>
        dark ? const Color(0xFFF6BF66) : const Color(0xFFB45309),
      ReviewModerationStatus.approved =>
        dark ? const Color(0xFF82D6BC) : const Color(0xFF047857),
      ReviewModerationStatus.rejected =>
        dark ? colors.error : const Color(0xFFB91C1C),
      _ => inProfileList ? colors.onSurfaceVariant : const Color(0xFF6B7280),
    };
    final muted =
        inProfileList ? colors.onSurfaceVariant : const Color(0xFF6B7280);
    final tagSummary = inProfileList && payload.tagScores.isNotEmpty
        ? payload.tagScores.entries
            .map((entry) =>
                '${reviewTagLabelsRu[entry.key] ?? entry.key}: ${entry.value}')
            .join(' · ')
        : payload.tagSummary;
    final title = Text(
      payload.entityLabel,
      maxLines: inProfileList ? null : 2,
      overflow: inProfileList ? null : TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w800,
      ),
    );
    final kind = Text(
      payload.entityType.labelRu,
      style: theme.textTheme.bodySmall?.copyWith(color: muted),
    );
    final moderation = Text(
      payload.moderationLabel,
      style: (inProfileList
              ? theme.textTheme.labelMedium
              : theme.textTheme.labelSmall)
          ?.copyWith(color: statusColor, fontWeight: FontWeight.w700),
    );

    return Material(
      color: inProfileList ? colors.surface : Colors.transparent,
      shape: inProfileList
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: colors.outlineVariant),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: inProfileList
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.white,
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showDemoBadge)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Пример',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: inProfileList
                          ? colors.primary
                          : const Color(0xFF6B21A8),
                    ),
                  ),
                ),
              if (inProfileList) ...[
                kind,
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(child: title),
                    if (onTap != null) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.chevron_right_rounded, color: muted),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.circle, size: 7, color: statusColor),
                    const SizedBox(width: 6),
                    Flexible(child: moderation),
                  ],
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(child: title),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: moderation,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                kind,
              ],
              const SizedBox(height: 8),
              Text(
                tagSummary,
                style: inProfileList
                    ? theme.textTheme.bodySmall?.copyWith(color: muted)
                    : theme.textTheme.bodyMedium,
              ),
              if (payload.bodyPreview != null &&
                  payload.bodyPreview!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  payload.bodyPreview!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: inProfileList
                        ? colors.onSurface
                        : const Color(0xFF374151),
                  ),
                ),
              ],
              if (payload.moderationReason != null &&
                  payload.moderationReason!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Комментарий модератора: ${payload.moderationReason!.trim()}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: dark
                        ? const Color(0xFFF6BF66)
                        : const Color(0xFFB45309),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (payload.openReports > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'Открытых жалоб: ${payload.openReports}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: dark ? colors.error : const Color(0xFFB91C1C),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact points balance chip for profile header.
class StudentPointsSummaryChip extends StatelessWidget {
  const StudentPointsSummaryChip({
    super.key,
    required this.summary,
    this.showDemoBadge = false,
  });

  final StudentPointsSummary summary;
  final bool showDemoBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.stars_rounded, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            '${summary.balance} балл.',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (showDemoBadge) ...[
            const SizedBox(width: 8),
            Text(
              'Пример',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
