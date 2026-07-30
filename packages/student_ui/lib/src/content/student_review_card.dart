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
  });

  final StudentReviewCardPayload payload;
  final bool showDemoBadge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = payload.moderationStatus;
    final statusColor = switch (status) {
      ReviewModerationStatus.pending => const Color(0xFFB45309),
      ReviewModerationStatus.approved => const Color(0xFF047857),
      ReviewModerationStatus.rejected => const Color(0xFFB91C1C),
      ReviewModerationStatus.draft => const Color(0xFF6B7280),
      null => const Color(0xFF6B7280),
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
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
                      color: const Color(0xFF6B21A8),
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      payload.entityLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      payload.moderationLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                payload.entityType.labelRu,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF6B7280),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                payload.tagSummary,
                style: theme.textTheme.bodyMedium,
              ),
              if (payload.bodyPreview != null &&
                  payload.bodyPreview!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  payload.bodyPreview!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF374151),
                  ),
                ),
              ],
              if (payload.moderationReason != null &&
                  payload.moderationReason!.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Комментарий модератора: ${payload.moderationReason!.trim()}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFB45309),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (payload.openReports > 0) ...[
                const SizedBox(height: 8),
                Text(
                  'Открытых жалоб: ${payload.openReports}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: const Color(0xFFB91C1C),
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
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.stars_rounded, size: 18, color: Color(0xFF6A4BBC)),
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
                color: const Color(0xFF6B21A8),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
