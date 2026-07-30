import 'package:student_ui/student_ui.dart';

import 'vacancy_item.dart';

class VacancyAdminListPartitions {
  const VacancyAdminListPartitions({
    required this.published,
    required this.drafts,
    required this.archived,
    required this.publishedPreviewItems,
  });

  final List<VacancyItem> published;
  final List<VacancyItem> drafts;
  final List<VacancyItem> archived;
  final List<VacancyItem> publishedPreviewItems;
}

List<VacancyItem> publishedVacancyPreviewItems(
  Iterable<VacancyItem> items, {
  DateTime? now,
}) {
  final moment = now ?? DateTime.now();
  final filtered = items.where((item) {
    if (item.status != VacancyStatus.published) return false;
    if (item.isHidden) return false;
    if (item.startsAt != null && item.startsAt!.isAfter(moment)) return false;
    if (item.endsAt != null && item.endsAt!.isBefore(moment)) return false;
    if (item.expiresAt != null && item.expiresAt!.isBefore(moment)) {
      return false;
    }
    return true;
  }).toList();
  filtered.sort((a, b) => b.priority.compareTo(a.priority));
  return filtered;
}

List<VacancyItem> _sortedByPriority(Iterable<VacancyItem> items) {
  final list = List<VacancyItem>.from(items);
  list.sort((a, b) => b.priority.compareTo(a.priority));
  return list;
}

bool _isDraftTabStatus(VacancyStatus status) {
  return status == VacancyStatus.draft ||
      status == VacancyStatus.submitted ||
      status == VacancyStatus.inModeration ||
      status == VacancyStatus.rejected ||
      status == VacancyStatus.approved;
}

bool _isArchivedTabStatus(VacancyStatus status) {
  return status == VacancyStatus.archived || status == VacancyStatus.expired;
}

VacancyAdminListPartitions partitionAdminVacancy(
  Iterable<VacancyItem> items, {
  DateTime? now,
}) {
  final all = List<VacancyItem>.from(items);
  return VacancyAdminListPartitions(
    published: _sortedByPriority(
      all.where((e) => e.status == VacancyStatus.published),
    ),
    drafts: _sortedByPriority(all.where((e) => _isDraftTabStatus(e.status))),
    archived: _sortedByPriority(
      all.where((e) => _isArchivedTabStatus(e.status)),
    ),
    publishedPreviewItems: publishedVacancyPreviewItems(all, now: now),
  );
}

extension VacancyStatusRu on VacancyStatus {
  String get russianLabel {
    switch (this) {
      case VacancyStatus.draft:
        return 'Черновик';
      case VacancyStatus.submitted:
        return 'Отправлена';
      case VacancyStatus.inModeration:
        return 'На модерации';
      case VacancyStatus.approved:
        return 'Одобрена';
      case VacancyStatus.published:
        return 'Опубликована';
      case VacancyStatus.expired:
        return 'Истекла';
      case VacancyStatus.archived:
        return 'В архиве';
      case VacancyStatus.rejected:
        return 'Отклонена';
    }
  }
}

extension VacancyItemPreview on VacancyItem {
  ManagedVacancyCard toManagedCard({bool? showDemoBadge}) {
    return ManagedVacancyCard(
      id: id.isEmpty ? 'preview' : id,
      origin: origin,
      payload: previewPayload,
      showDemoBadge: showDemoBadge ?? origin == ContentOrigin.demo,
      hasContacts: contacts.isNotEmpty,
      expiresAt: expiresAt,
    );
  }
}
