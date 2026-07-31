import 'home_promo_item.dart';

/// Splits the admin list from the student phone-preview feed.
class HomePromoAdminListPartitions {
  const HomePromoAdminListPartitions({
    required this.allAdminItems,
    required this.published,
    required this.drafts,
    required this.archived,
    required this.publishedPreviewItems,
  });

  final List<HomePromoItem> allAdminItems;
  final List<HomePromoItem> published;
  final List<HomePromoItem> drafts;
  final List<HomePromoItem> archived;
  final List<HomePromoItem> publishedPreviewItems;
}

List<HomePromoItem> homePromoPublishedPreviewItems(
  Iterable<HomePromoItem> allAdminItems, {
  DateTime? now,
}) {
  final moment = now ?? DateTime.now();
  final filtered = allAdminItems.where((item) {
    if (!item.isPublished || item.isHidden) return false;
    if (item.startsAt != null && item.startsAt!.isAfter(moment)) {
      return false;
    }
    if (item.endsAt != null && item.endsAt!.isBefore(moment)) {
      return false;
    }
    return true;
  }).toList();

  filtered.sort((a, b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return b.priority.compareTo(a.priority);
  });
  return filtered;
}

List<HomePromoItem> _sortedByAdminOrder(Iterable<HomePromoItem> items) {
  final list = List<HomePromoItem>.from(items);
  list.sort((a, b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return b.priority.compareTo(a.priority);
  });
  return list;
}

HomePromoAdminListPartitions partitionAdminHomePromo(
  Iterable<HomePromoItem> allAdminItems, {
  DateTime? now,
}) {
  final all = List<HomePromoItem>.from(allAdminItems);
  return HomePromoAdminListPartitions(
    allAdminItems: all,
    published: _sortedByAdminOrder(all.where((e) => e.isPublished)),
    drafts: _sortedByAdminOrder(all.where((e) => e.isDraft)),
    archived: _sortedByAdminOrder(all.where((e) => e.isArchived)),
    publishedPreviewItems: homePromoPublishedPreviewItems(all, now: now),
  );
}
