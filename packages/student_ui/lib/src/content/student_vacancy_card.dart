import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'vacancy_models.dart';

/// Shared vacancy card renderer (Mobile + Admin Preview).
///
/// Never pass raw JSON — only [VacancyCardPayload].
class StudentVacancyCard extends StatelessWidget {
  const StudentVacancyCard({
    super.key,
    required this.payload,
    this.showDemoBadge = false,
    this.expiresLabel,
    this.hasContacts = false,
    this.onTap,
    this.logoBytes,
    this.coverBytes,
    this.backgroundBytes,
  });

  final VacancyCardPayload payload;
  final bool showDemoBadge;
  final String? expiresLabel;
  final bool hasContacts;
  final VoidCallback? onTap;
  final Uint8List? logoBytes;
  final Uint8List? coverBytes;

  /// Optional soft background plane behind the card surface.
  final Uint8List? backgroundBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBackground =
        backgroundBytes != null && backgroundBytes!.isNotEmpty;
    final card = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: Colors.white.withValues(alpha: hasBackground ? 0.94 : 1),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [
              BoxShadow(
                color: payload.accentColor.withValues(alpha: 0.12),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 5,
                  decoration: BoxDecoration(
                    color: payload.accentColor,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(16),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (coverBytes != null && coverBytes!.isNotEmpty) ...[
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(
                              coverBytes!,
                              height: 88,
                              width: double.infinity,
                              fit: BoxFit.cover,
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
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
                        if (logoBytes != null && logoBytes!.isNotEmpty) ...[
                          Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.memory(
                                  logoBytes!,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  payload.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ] else
                          Text(
                            payload.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        if (payload.companyName.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            payload.companyName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF6B7280),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        if (payload.formatLine.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            payload.formatLine,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF374151),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        if (payload.salaryText != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            payload.salaryText!,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF111827),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          payload.summary,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF4B5563),
                          ),
                        ),
                        if (payload.tags.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in payload.tags.take(4))
                                Chip(
                                  label: Text(tag),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: EdgeInsets.zero,
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            if (expiresLabel != null)
                              Expanded(
                                child: Text(
                                  expiresLabel!,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: const Color(0xFF9CA3AF),
                                  ),
                                ),
                              ),
                            if (hasContacts)
                              Text(
                                'Есть контакты',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: const Color(0xFF059669),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (!hasBackground) return card;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: Image.memory(
              backgroundBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ),
          card,
        ],
      ),
    );
  }
}

String? vacancyExpiresLabel(DateTime? expiresAt) {
  if (expiresAt == null) return null;
  final local = expiresAt.toLocal();
  final day = local.day.toString().padLeft(2, '0');
  final month = local.month.toString().padLeft(2, '0');
  return 'Актуально до $day.$month.${local.year}';
}
