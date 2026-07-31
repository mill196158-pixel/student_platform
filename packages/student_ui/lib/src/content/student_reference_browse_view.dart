import 'package:flutter/material.dart';

import 'reference_article_models.dart';
import 'student_reference_article_card.dart';

/// Shared Mobile/Admin phone-screen browse UI for the reference section.
///
/// Renders an AppBar titled «Справочник», optional category chips, and
/// article cards grouped by category. Pass either [bundle] or both
/// [categories] + [articles].
class StudentReferenceBrowseView extends StatefulWidget {
  const StudentReferenceBrowseView({
    super.key,
    this.bundle,
    this.categories,
    this.articles,
    this.onArticleTap,
    this.selectedArticleId,
    this.query = '',
    this.emptyMessage = 'Справочник пока пуст',
    this.showDemoBadge = false,
  }) : assert(
          bundle != null || (categories != null && articles != null),
          'Provide bundle, or both categories and articles',
        );

  final ReferenceBundle? bundle;
  final List<ReferenceCategory>? categories;
  final List<ManagedReferenceArticle>? articles;
  final ValueChanged<ManagedReferenceArticle>? onArticleTap;
  final String? selectedArticleId;
  final String query;
  final String emptyMessage;
  final bool showDemoBadge;

  @override
  State<StudentReferenceBrowseView> createState() =>
      _StudentReferenceBrowseViewState();
}

class _StudentReferenceBrowseViewState
    extends State<StudentReferenceBrowseView> {
  String? _selectedCategoryId;

  List<ReferenceCategory> get _categories =>
      widget.categories ?? widget.bundle?.categories ?? const [];

  List<ManagedReferenceArticle> get _articles =>
      widget.articles ?? widget.bundle?.articles ?? const [];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filtered = _articles
        .where((article) => article.matchesQuery(widget.query))
        .where(
          (article) =>
              _selectedCategoryId == null ||
              article.categoryId == _selectedCategoryId,
        )
        .toList()
      ..sort((a, b) {
        final byCategory = a.categoryTitle.compareTo(b.categoryTitle);
        if (byCategory != 0) return byCategory;
        return a.sortOrder.compareTo(b.sortOrder);
      });

    final groups = <String, List<ManagedReferenceArticle>>{};
    for (final article in filtered) {
      groups.putIfAbsent(article.categoryTitle, () => []).add(article);
    }

    final sortedCategories = [..._categories]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return Scaffold(
      backgroundColor: const Color(0xFFFAF8FC),
      appBar: AppBar(
        title: const Text(
          'Справочник',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: Color(0xFF111827),
          ),
        ),
        centerTitle: false,
        elevation: 0,
        backgroundColor: const Color(0xFFFAF8FC),
        foregroundColor: const Color(0xFF111827),
        surfaceTintColor: Colors.transparent,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (sortedCategories.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: const Text('Все'),
                      selected: _selectedCategoryId == null,
                      onSelected: (_) {
                        setState(() => _selectedCategoryId = null);
                      },
                      selectedColor:
                          const Color(0xFF6A4BBC).withValues(alpha: 0.16),
                      checkmarkColor: const Color(0xFF6A4BBC),
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _selectedCategoryId == null
                            ? const Color(0xFF6A4BBC)
                            : Colors.black87,
                      ),
                    ),
                  ),
                  for (final category in sortedCategories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        avatar: Icon(
                          category.iconData,
                          size: 16,
                          color: _selectedCategoryId == category.id
                              ? const Color(0xFF6A4BBC)
                              : Colors.black54,
                        ),
                        label: Text(category.title),
                        selected: _selectedCategoryId == category.id,
                        onSelected: (_) {
                          setState(() {
                            _selectedCategoryId =
                                _selectedCategoryId == category.id
                                    ? null
                                    : category.id;
                          });
                        },
                        selectedColor:
                            const Color(0xFF6A4BBC).withValues(alpha: 0.16),
                        checkmarkColor: const Color(0xFF6A4BBC),
                        labelStyle: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: _selectedCategoryId == category.id
                              ? const Color(0xFF6A4BBC)
                              : Colors.black87,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        widget.query.trim().isEmpty
                            ? widget.emptyMessage
                            : 'По запросу ничего не найдено',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.black54,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      for (final entry in groups.entries)
                        _ReferenceCategorySection(
                          title: entry.key,
                          children: [
                            for (final article in entry.value)
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(26),
                                  border: article.id == widget.selectedArticleId
                                      ? Border.all(
                                          color: const Color(0xFF6656D9),
                                          width: 2,
                                        )
                                      : null,
                                ),
                                child: StudentReferenceArticleCard(
                                  article: article,
                                  showDemoBadge: widget.showDemoBadge ||
                                      article.showDemoBadge,
                                  onTap: widget.onArticleTap == null
                                      ? null
                                      : () => widget.onArticleTap!(article),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _ReferenceCategorySection extends StatelessWidget {
  const _ReferenceCategorySection({
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
