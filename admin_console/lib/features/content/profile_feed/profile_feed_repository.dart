import 'package:student_ui/student_ui.dart';

import 'profile_feed_item.dart';

class ProfileFeedAudiencePreview {
  const ProfileFeedAudiencePreview({
    required this.recipientCount,
    required this.audienceMode,
    this.groupCount = 0,
    this.explicitUserCount = 0,
  });

  final int recipientCount;
  final String audienceMode;
  final int groupCount;
  final int explicitUserCount;

  factory ProfileFeedAudiencePreview.fromJson(Map<String, dynamic> json) {
    final breakdown = json['breakdown'];
    final breakdownMap =
        breakdown is Map ? Map<String, dynamic>.from(breakdown) : const {};
    final groups = breakdownMap['groups'];
    final groupCount = groups is List
        ? groups.length
        : int.tryParse('${json['group_count'] ?? 0}') ?? 0;
    final explicit = int.tryParse(
          '${breakdownMap['explicit_users_count'] ?? json['explicit_users_count'] ?? 0}',
        ) ??
        0;
    return ProfileFeedAudiencePreview(
      recipientCount: int.tryParse('${json['recipient_count'] ?? 0}') ?? 0,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      groupCount: groupCount,
      explicitUserCount: explicit,
    );
  }
}

abstract class ProfileFeedRepository {
  Future<List<ProfileFeedItem>> list({String? status});

  Future<ProfileFeedItem> createDraft({
    required ProfileFeedPayload payload,
    String? title,
    ContentOrigin origin = ContentOrigin.admin,
  });

  Future<ProfileFeedItem> updateDraft(ProfileFeedItem item);

  Future<ProfileFeedItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  });

  Future<ProfileFeedItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  });

  Future<ProfileFeedAudiencePreview> previewAudience(String id);

  Future<ProfileFeedItem> publish(String id, int expectedRowVersion);

  Future<ProfileFeedItem> archive(String id, int expectedRowVersion);

  Future<void> reorder(List<String> orderedIds, List<int> expectedRowVersions);
}

class ProfileFeedRepositoryException implements Exception {
  const ProfileFeedRepositoryException(
    this.message, {
    this.isForbidden = false,
  });

  final String message;
  final bool isForbidden;

  @override
  String toString() => message;
}

/// In-memory demo repository for local prototype / offline Admin.
class LocalProfileFeedRepository implements ProfileFeedRepository {
  LocalProfileFeedRepository() {
    _items = [
      for (var i = 0; i < ProfileFeedPayload.demoFeed.length; i++)
        ProfileFeedItem(
          id: 'local-demo-profile-feed-$i',
          status: ProfileFeedStatus.published,
          origin: ContentOrigin.demo,
          title: ProfileFeedPayload.demoFeed[i].title,
          payload: ProfileFeedPayload.demoFeed[i],
          rowVersion: 1,
          priority: 0,
          sortOrder: i,
          audienceMode: 'all',
        ),
    ];
  }

  late List<ProfileFeedItem> _items;
  int _seq = 1;

  @override
  Future<List<ProfileFeedItem>> list({String? status}) async {
    final filtered = status == null
        ? _items
        : _items
            .where((e) => profileFeedStatusWire(e.status) == status)
            .toList();
    final copy = [...filtered]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return copy;
  }

  @override
  Future<ProfileFeedItem> createDraft({
    required ProfileFeedPayload payload,
    String? title,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final item = ProfileFeedItem(
      id: 'local-profile-feed-${_seq++}',
      status: ProfileFeedStatus.draft,
      origin: origin,
      title: title ?? payload.title,
      payload: payload,
      rowVersion: 1,
      priority: 0,
      sortOrder: _items.length,
      audienceMode: 'all',
    );
    _items = [..._items, item];
    return item;
  }

  @override
  Future<ProfileFeedItem> updateDraft(ProfileFeedItem item) async {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      throw const ProfileFeedRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.status != ProfileFeedStatus.draft) {
      throw const ProfileFeedRepositoryException(
        'Редактировать можно только черновик.',
      );
    }
    final next = item.copyWith(rowVersion: current.rowVersion + 1);
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<ProfileFeedItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ProfileFeedRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      sortOrder: sortOrder,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<ProfileFeedItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  }) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ProfileFeedRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      audienceMode: audienceMode,
      audienceGroupIds: groupIds,
      audienceUserIds: userIds,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<ProfileFeedAudiencePreview> previewAudience(String id) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ProfileFeedRepositoryException('Карточка не найдена.');
    }
    final item = _items[idx];
    final count = switch (item.audienceMode) {
      'all' => 100,
      'groups' => item.audienceGroupIds.length * 10,
      'users' => item.audienceUserIds.length,
      'groups_and_users' =>
        item.audienceGroupIds.length * 10 + item.audienceUserIds.length,
      _ => 0,
    };
    return ProfileFeedAudiencePreview(
      recipientCount: count,
      audienceMode: item.audienceMode,
      groupCount: item.audienceGroupIds.length,
      explicitUserCount: item.audienceUserIds.length,
    );
  }

  @override
  Future<ProfileFeedItem> publish(String id, int expectedRowVersion) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ProfileFeedRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      status: ProfileFeedStatus.published,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<ProfileFeedItem> archive(String id, int expectedRowVersion) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ProfileFeedRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      status: ProfileFeedStatus.archived,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<void> reorder(
    List<String> orderedIds,
    List<int> expectedRowVersions,
  ) async {
    if (orderedIds.length != expectedRowVersions.length) {
      throw const ProfileFeedRepositoryException('Некорректный порядок.');
    }
    final next = <ProfileFeedItem>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final idx = _items.indexWhere((e) => e.id == orderedIds[i]);
      if (idx < 0) {
        throw const ProfileFeedRepositoryException('Карточка не найдена.');
      }
      final current = _items[idx];
      if (current.rowVersion != expectedRowVersions[i]) {
        throw const ProfileFeedRepositoryException(
          'Карточка изменилась. Обновите список.',
        );
      }
      next.add(
        current.copyWith(
          sortOrder: i,
          rowVersion: current.rowVersion + 1,
        ),
      );
    }
    final remaining = _items.where((e) => !orderedIds.contains(e.id));
    _items = [...next, ...remaining];
  }
}
