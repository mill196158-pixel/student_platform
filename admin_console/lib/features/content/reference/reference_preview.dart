import 'package:student_ui/student_ui.dart';

import 'reference_item.dart';

class ReferenceAdminListPartitions {
  const ReferenceAdminListPartitions({
    required this.allAdminItems,
    required this.published,
    required this.drafts,
    required this.archived,
    required this.publishedPreviewItems,
  });

  final List<ReferenceArticleItem> allAdminItems;
  final List<ReferenceArticleItem> published;
  final List<ReferenceArticleItem> drafts;
  final List<ReferenceArticleItem> archived;
  final List<ReferenceArticleItem> publishedPreviewItems;
}

List<ReferenceArticleItem> publishedReferencePreviewItems(
  Iterable<ReferenceArticleItem> allAdminItems,
) {
  final filtered = allAdminItems
      .where((item) => item.status == ReferenceArticleStatus.published)
      .toList();
  filtered.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return filtered;
}

List<ReferenceArticleItem> _sortedByAdminOrder(
  Iterable<ReferenceArticleItem> items,
) {
  final list = List<ReferenceArticleItem>.from(items);
  list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return list;
}

ReferenceAdminListPartitions partitionAdminReference(
  Iterable<ReferenceArticleItem> allAdminItems,
) {
  final all = List<ReferenceArticleItem>.from(allAdminItems);
  return ReferenceAdminListPartitions(
    allAdminItems: all,
    published: _sortedByAdminOrder(
      all.where((e) => e.status == ReferenceArticleStatus.published),
    ),
    drafts: _sortedByAdminOrder(
      all.where((e) => e.status == ReferenceArticleStatus.draft),
    ),
    archived: _sortedByAdminOrder(
      all.where((e) => e.status == ReferenceArticleStatus.archived),
    ),
    publishedPreviewItems: publishedReferencePreviewItems(all),
  );
}

extension ReferenceArticleStatusRu on ReferenceArticleStatus {
  String get russianLabel => switch (this) {
    ReferenceArticleStatus.draft => 'Черновик',
    ReferenceArticleStatus.published => 'Опубликован',
    ReferenceArticleStatus.archived => 'В архиве',
  };
}

extension ReferenceArticleItemPreview on ReferenceArticleItem {
  ManagedReferenceArticle toManagedArticle({
    String? categoryTitleOverride,
    bool? showDemoBadge,
  }) {
    return ManagedReferenceArticle(
      id: id.isEmpty ? 'preview' : id,
      title: title,
      schemaVersion: schemaVersion,
      origin: origin,
      sortOrder: sortOrder,
      categoryId: categoryId,
      categoryTitle: categoryTitleOverride ?? categoryTitle ?? '',
      payload: payload,
      showDemoBadge: showDemoBadge ?? origin == ContentOrigin.demo,
    );
  }
}
