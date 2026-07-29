import 'package:flutter/material.dart';

import 'reference_article_models.dart';

/// List card for a reference article (Mobile + Admin preview).
///
/// Template: `reference_article_v1`. Never pass raw JSON or HTML.
class StudentReferenceArticleCard extends StatelessWidget {
  const StudentReferenceArticleCard({
    super.key,
    required this.article,
    this.onTap,
    this.showDemoBadge = false,
  });

  final ManagedReferenceArticle article;
  final VoidCallback? onTap;
  final bool showDemoBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payload = article.payload;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surface,
                const Color(0xFFF8F4FF),
              ],
            ),
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.045),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  payload.iconData,
                  color: const Color(0xFF6A4BBC),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showDemoBadge || article.showDemoBadge)
                      Text(
                        'Пример',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF6A4BBC),
                        ),
                      ),
                    Text(
                      article.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      payload.shortText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black.withValues(alpha: 0.62),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.black38),
            ],
          ),
        ),
      ),
    );
  }
}

/// Safe detail preview listing typed blocks (no HTML/WebView).
class StudentReferenceArticleDetail extends StatelessWidget {
  const StudentReferenceArticleDetail({
    super.key,
    required this.article,
    this.onReportError,
    this.onOpenAsset,
    this.onOpenUrl,
    this.onOpenCta,
    this.showDemoBadge = false,
  });

  final ManagedReferenceArticle article;
  final VoidCallback? onReportError;

  /// Opens a content-media asset (image/file) by asset id.
  final ValueChanged<String>? onOpenAsset;

  /// Opens an external or in-app URL from a link block.
  final ValueChanged<String>? onOpenUrl;

  /// Opens the article-level or block CTA destination.
  final ValueChanged<ReferenceArticleCta>? onOpenCta;
  final bool showDemoBadge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payload = article.payload;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF6A4BBC).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(payload.iconData, color: const Color(0xFF6A4BBC)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showDemoBadge || article.showDemoBadge)
                      Text(
                        'Пример',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF6A4BBC),
                        ),
                      ),
                    Text(
                      article.title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      article.categoryTitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            payload.shortText,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          for (final block in payload.blocks)
            _ReferenceBlockTile(
              block: block,
              onOpenAsset: onOpenAsset,
              onOpenUrl: onOpenUrl,
              onOpenCta: onOpenCta,
            ),
          if (payload.cta != null) ...[
            const SizedBox(height: 12),
            _ReferenceCtaTile(
              cta: payload.cta!,
              onOpenCta: onOpenCta,
            ),
          ],
          if (onReportError != null) ...[
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onReportError,
              icon: const Icon(Icons.flag_outlined),
              label: const Text('Сообщить об ошибке'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReferenceBlockTile extends StatelessWidget {
  const _ReferenceBlockTile({
    required this.block,
    this.onOpenAsset,
    this.onOpenUrl,
    this.onOpenCta,
  });

  final ReferenceBlock block;
  final ValueChanged<String>? onOpenAsset;
  final ValueChanged<String>? onOpenUrl;
  final ValueChanged<ReferenceArticleCta>? onOpenCta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: switch (block) {
        ReferenceTextBlock(:final text) => Text(
            text,
            style: theme.textTheme.bodyMedium,
          ),
        ReferenceImageBlock(:final assetId, :final caption) => _IconRow(
            icon: Icons.image_outlined,
            title: caption ?? 'Изображение',
            subtitle: assetId.isEmpty
                ? 'Медиа не привязано'
                : (onOpenAsset == null ? 'asset:$assetId' : 'Открыть изображение'),
            onTap: assetId.isEmpty || onOpenAsset == null
                ? null
                : () => onOpenAsset!(assetId),
          ),
        ReferenceFileBlock(:final title, :final assetId) => _IconRow(
            icon: Icons.insert_drive_file_outlined,
            title: title ?? 'Файл',
            subtitle: assetId.isEmpty
                ? 'Медиа не привязано'
                : (onOpenAsset == null
                    ? 'Скачивание через content-media'
                    : 'Открыть файл'),
            onTap: assetId.isEmpty || onOpenAsset == null
                ? null
                : () => onOpenAsset!(assetId),
          ),
        ReferenceLinkBlock(:final label, :final url) => _IconRow(
            icon: Icons.link_rounded,
            title: label,
            subtitle: url,
            onTap: url.trim().isEmpty || onOpenUrl == null
                ? null
                : () => onOpenUrl!(url),
          ),
        ReferenceCtaBlock(:final cta) => _ReferenceCtaTile(
            cta: cta,
            onOpenCta: onOpenCta,
          ),
      },
    );
  }
}

class _ReferenceCtaTile extends StatelessWidget {
  const _ReferenceCtaTile({
    required this.cta,
    this.onOpenCta,
  });

  final ReferenceArticleCta cta;
  final ValueChanged<ReferenceArticleCta>? onOpenCta;

  @override
  Widget build(BuildContext context) {
    final destination = cta.route ?? cta.url ?? '';
    return _IconRow(
      icon: Icons.open_in_new_rounded,
      title: cta.label,
      subtitle: destination.isEmpty ? null : destination,
      onTap: destination.isEmpty || onOpenCta == null
          ? null
          : () => onOpenCta!(cta),
    );
  }
}

class _IconRow extends StatelessWidget {
  const _IconRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: const Color(0xFF6A4BBC)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.black54,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (onTap != null)
          const Icon(Icons.chevron_right_rounded, size: 18, color: Colors.black38),
      ],
    );
    if (onTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: row,
        ),
      ),
    );
  }
}
