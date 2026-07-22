import 'news_item.dart';

/// Splits the admin list from the student phone-preview feed.
///
/// Admin list sources (`drafts` / `published` / `archived`) are status partitions
/// of [allAdminItems]. Phone preview uses [publishedPreviewItems], mirroring the
/// visibility rules of `get_my_published_news` (without per-student audience
/// membership — admin preview shows every schedule-active published card).
class NewsAdminListPartitions {
  const NewsAdminListPartitions({
    required this.allAdminItems,
    required this.published,
    required this.drafts,
    required this.archived,
    required this.publishedPreviewItems,
  });

  final List<NewsItem> allAdminItems;
  final List<NewsItem> published;
  final List<NewsItem> drafts;
  final List<NewsItem> archived;

  /// Same status/schedule/hidden rules as student feed RPC.
  final List<NewsItem> publishedPreviewItems;
}

/// Returns items that would appear in a student feed right now.
///
/// Mirrors `get_my_published_news`:
/// - `status = published`
/// - `not is_hidden`
/// - `starts_at is null or starts_at <= now`
/// - `ends_at is null or ends_at >= now`
///
/// Audience membership is not applied in Admin preview so editors can still
/// see group-targeted published cards they are working on.
List<NewsItem> publishedPreviewItems(
  Iterable<NewsItem> allAdminItems, {
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
    final byPriority = b.priority.compareTo(a.priority);
    if (byPriority != 0) return byPriority;
    final aPub =
        a.publishedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bPub =
        b.publishedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bPub.compareTo(aPub);
  });
  return filtered;
}

List<NewsItem> _sortedByAdminOrder(Iterable<NewsItem> items) {
  final list = List<NewsItem>.from(items);
  list.sort((a, b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return b.priority.compareTo(a.priority);
  });
  return list;
}

NewsAdminListPartitions partitionAdminNews(
  Iterable<NewsItem> allAdminItems, {
  DateTime? now,
}) {
  final all = List<NewsItem>.from(allAdminItems);
  return NewsAdminListPartitions(
    allAdminItems: all,
    published: _sortedByAdminOrder(all.where((e) => e.isPublished)),
    drafts: _sortedByAdminOrder(all.where((e) => e.isDraft)),
    archived: _sortedByAdminOrder(all.where((e) => e.isArchived)),
    publishedPreviewItems: publishedPreviewItems(all, now: now),
  );
}
