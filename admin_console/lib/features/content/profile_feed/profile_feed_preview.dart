import 'profile_feed_item.dart';

class ProfileFeedAdminListPartitions {
  const ProfileFeedAdminListPartitions({
    required this.allAdminItems,
    required this.published,
    required this.drafts,
    required this.archived,
    required this.publishedPreviewItems,
  });

  final List<ProfileFeedItem> allAdminItems;
  final List<ProfileFeedItem> published;
  final List<ProfileFeedItem> drafts;
  final List<ProfileFeedItem> archived;
  final List<ProfileFeedItem> publishedPreviewItems;
}

List<ProfileFeedItem> publishedProfileFeedPreviewItems(
  Iterable<ProfileFeedItem> allAdminItems, {
  DateTime? now,
}) {
  final moment = now ?? DateTime.now();
  final filtered = allAdminItems.where((item) {
    if (item.status != ProfileFeedStatus.published) return false;
    if (item.startsAt != null && item.startsAt!.isAfter(moment)) return false;
    if (item.endsAt != null && item.endsAt!.isBefore(moment)) return false;
    return true;
  }).toList();

  filtered.sort((a, b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return b.priority.compareTo(a.priority);
  });
  return filtered;
}

List<ProfileFeedItem> _sortedByAdminOrder(Iterable<ProfileFeedItem> items) {
  final list = List<ProfileFeedItem>.from(items);
  list.sort((a, b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    if (byOrder != 0) return byOrder;
    return b.priority.compareTo(a.priority);
  });
  return list;
}

ProfileFeedAdminListPartitions partitionAdminProfileFeed(
  Iterable<ProfileFeedItem> allAdminItems, {
  DateTime? now,
}) {
  final all = List<ProfileFeedItem>.from(allAdminItems);
  return ProfileFeedAdminListPartitions(
    allAdminItems: all,
    published: _sortedByAdminOrder(
      all.where((e) => e.status == ProfileFeedStatus.published),
    ),
    drafts: _sortedByAdminOrder(
      all.where((e) => e.status == ProfileFeedStatus.draft),
    ),
    archived: _sortedByAdminOrder(
      all.where((e) => e.status == ProfileFeedStatus.archived),
    ),
    publishedPreviewItems: publishedProfileFeedPreviewItems(all, now: now),
  );
}
