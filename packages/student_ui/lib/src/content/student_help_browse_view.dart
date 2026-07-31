import 'package:flutter/material.dart';

import 'reference_article_models.dart';
import 'student_reference_article_card.dart';

/// Presentation-only Help / reference browse for Admin phone preview / Mobile.
///
/// Matches mobile help chrome (summary card + grouped articles), not the
/// Admin FilterChip AppBar used by [StudentReferenceBrowseView].
///
/// Keep [StudentReferenceBrowseView] for backward compatibility; new Admin
/// editors should use this widget.
class StudentHelpBrowseView extends StatelessWidget {
  const StudentHelpBrowseView({
    super.key,
    required this.articles,
    this.selectedArticle,
    this.onOpenArticle,
    this.onBack,
    this.summaryTitle = 'Справочник',
    this.summarySubtitle =
        'Короткие ответы про доступы, учёбу и сервисы кампуса.',
    this.emptyMessage = 'Справочник пока пуст',
    this.showDemoBadge = false,
    this.selectedArticleId,
  });

  final List<ManagedReferenceArticle> articles;

  /// When non-null, show detail with back instead of the browse list.
  final ManagedReferenceArticle? selectedArticle;
  final ValueChanged<ManagedReferenceArticle>? onOpenArticle;
  final VoidCallback? onBack;

  final String summaryTitle;
  final String summarySubtitle;
  final String emptyMessage;
  final bool showDemoBadge;

  /// Optional highlight id while browsing the list.
  final String? selectedArticleId;

  static const _bg = Color(0xFFFAF8FC);
  static const _title = Color(0xFF111827);
  static const _lavenderStart = Color(0xFFDCD0FA);
  static const _lavenderEnd = Color(0xFFC9B8F3);
  static const _accent = Color(0xFF5B4B8A);

  @override
  Widget build(BuildContext context) {
    final detail = selectedArticle;
    if (detail != null) {
      return ColoredBox(
        color: _bg,
        child: StudentReferenceArticleDetail(
          article: detail,
          showDemoBadge: showDemoBadge || detail.showDemoBadge,
          onBack: onBack,
        ),
      );
    }

    final sorted = [...articles]..sort((a, b) {
        final byCategory = a.categoryTitle.compareTo(b.categoryTitle);
        if (byCategory != 0) return byCategory;
        return a.sortOrder.compareTo(b.sortOrder);
      });

    final groups = <String, List<ManagedReferenceArticle>>{};
    for (final article in sorted) {
      groups.putIfAbsent(article.categoryTitle, () => []).add(article);
    }

    return ColoredBox(
      color: _bg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _HelpSummaryCard(
            title: summaryTitle,
            subtitle: summarySubtitle,
          ),
          const SizedBox(height: 12),
          if (sorted.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                emptyMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Colors.black54,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            )
          else
            for (final entry in groups.entries)
              _HelpCategorySection(
                title: entry.key,
                children: [
                  for (final article in entry.value)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        border: article.id == selectedArticleId
                            ? Border.all(color: _accent, width: 2)
                            : null,
                      ),
                      child: StudentReferenceArticleCard(
                        article: article,
                        showDemoBadge: showDemoBadge || article.showDemoBadge,
                        onTap: onOpenArticle == null
                            ? null
                            : () => onOpenArticle!(article),
                      ),
                    ),
                ],
              ),
        ],
      ),
    );
  }
}

class _HelpSummaryCard extends StatelessWidget {
  const _HelpSummaryCard({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            StudentHelpBrowseView._lavenderStart,
            StudentHelpBrowseView._lavenderEnd,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: StudentHelpBrowseView._lavenderEnd.withValues(alpha: 0.28),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.help_outline_rounded,
              color: StudentHelpBrowseView._accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: StudentHelpBrowseView._title,
                        fontWeight: FontWeight.w900,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF374151),
                        height: 1.3,
                        fontWeight: FontWeight.w600,
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

class _HelpCategorySection extends StatelessWidget {
  const _HelpCategorySection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}
