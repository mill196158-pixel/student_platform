import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'profile_feed_item.dart';
import '../shared/local_content_working_draft.dart';

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
    final breakdownMap = breakdown is Map
        ? Map<String, dynamic>.from(breakdown)
        : const {};
    final groups = breakdownMap['groups'];
    final groupCount = groups is List
        ? groups.length
        : int.tryParse('${json['group_count'] ?? 0}') ?? 0;
    final explicit =
        int.tryParse(
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
    ProfileFeedPayload? payload,
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

  Future<ProfileFeedItem> unpublish(String id, int expectedRowVersion);

  Future<ProfileFeedItem> archive(String id, int expectedRowVersion);

  Future<ProfileFeedItem> restoreArchived(String id, int expectedRowVersion);

  Future<ProfileFeedDeleteResult> safeDelete(String id, int expectedRowVersion);

  Future<ProfileFeedItem> duplicate(String id);

  Future<ProfileFeedItem> promoteDemo(String id, int expectedRowVersion);

  Future<void> reorder(List<String> orderedIds, List<int> expectedRowVersions);

  Future<List<ProfileFeedVersionInfo>> listVersions(String id);

  Future<ProfileFeedItem> restoreVersion(
    String id,
    int versionNumber,
    int expectedRowVersion,
  );

  Future<ProfileFeedItem> beginEdit(String id);

  Future<ProfileFeedItem> saveWorkingDraft(
    ProfileFeedItem item, {
    required int expectedDraftRowVersion,
  });

  Future<ProfileFeedItem> publishWorkingDraft(
    String id, {
    required int expectedDraftRowVersion,
  });

  Future<ProfileFeedItem> discardWorkingDraft(String id);
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
    const legacyKeys = [
      'content:profile_feed:about',
      'content:profile_feed:schedule',
      'content:profile_feed:discounts',
    ];
    _items = [
      for (var i = 0; i < ProfileFeedPayload.demoFeed.length; i++)
        ProfileFeedItem(
          id: 'local-demo-profile-feed-$i',
          status: ProfileFeedStatus.published,
          origin: ContentOrigin.demo,
          title: ProfileFeedPayload.demoFeed[i].title,
          payload: ProfileFeedPayload.demoFeed[i],
          legacyKey: legacyKeys[i],
          rowVersion: 1,
          versionNumber: 1,
          priority: 0,
          sortOrder: i,
          audienceMode: 'all',
        ),
    ];
    for (final item in _items) {
      _versions[item.id] = [item];
    }
  }

  late List<ProfileFeedItem> _items;
  int _seq = 1;
  final Map<String, List<ProfileFeedItem>> _versions = {};
  final Map<String, _ProfileFeedWorkingDraft> _workingDrafts = {};

  void _recordVersion(ProfileFeedItem item) {
    final list = _versions.putIfAbsent(item.id, () => []);
    list.add(item);
  }

  int _indexOf(String id) {
    final index = _items.indexWhere((e) => e.id == id);
    if (index < 0) {
      throw const ProfileFeedRepositoryException('Карточка не найдена.');
    }
    return index;
  }

  ProfileFeedItem _bump(ProfileFeedItem item) {
    return item.copyWith(
      rowVersion: item.rowVersion + 1,
      versionNumber: item.versionNumber + 1,
    );
  }

  ProfileFeedItem _withWorkingDraftFlag(ProfileFeedItem item) {
    if (!_workingDrafts.containsKey(item.id)) return item;
    return item.copyWith(hasWorkingDraft: true);
  }

  ProfileFeedItem _withWorkingDraftOverlay(ProfileFeedItem item) {
    final draft = _workingDrafts[item.id];
    if (draft == null) return item;
    return item.copyWith(
      title: draft.title,
      payload: draft.payload,
      priority: draft.priority,
      sortOrder: draft.sortOrder,
      audienceMode: draft.audienceMode,
      startsAt: draft.startsAt,
      endsAt: draft.endsAt,
      audienceGroupIds: draft.audienceGroupIds,
      audienceUserIds: draft.audienceUserIds,
      hasWorkingDraft: true,
      workingDraftRowVersion: draft.rowVersion,
    );
  }

  void _assertNoWorkingDraft(String id) {
    assertNoLocalWorkingDraft(_workingDrafts, id);
  }

  @override
  Future<List<ProfileFeedItem>> list({String? status}) async {
    final filtered = status == null
        ? _items
        : _items
              .where((e) => profileFeedStatusWire(e.status) == status)
              .toList();
    final copy = [...filtered.map(_withWorkingDraftFlag)]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return copy;
  }

  @override
  Future<ProfileFeedItem> createDraft({
    ProfileFeedPayload? payload,
    String? title,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final basePayload =
        payload ??
        ProfileFeedPayload(
          title: 'Новая карточка',
          subtitle: 'Краткое описание',
          ctaLabel: 'Открыть',
          iconKey: 'info',
          gradientColors: const [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
          cardVariant: 'gradient_text',
          gradientAngle: 45,
          ctaRoute: '/profile',
        );
    final item = ProfileFeedItem(
      id: 'local-profile-feed-${_seq++}',
      status: ProfileFeedStatus.draft,
      origin: origin,
      title: title ?? basePayload.title,
      payload: basePayload,
      rowVersion: 1,
      versionNumber: 1,
      priority: 0,
      sortOrder: _items.length,
      audienceMode: 'all',
    );
    _items = [..._items, item];
    _recordVersion(item);
    return item;
  }

  @override
  Future<ProfileFeedItem> updateDraft(ProfileFeedItem item) async {
    final idx = _indexOf(item.id);
    final current = _items[idx];
    if (current.isArchived) {
      throw const ProfileFeedRepositoryException(
        'Архивную карточку нельзя изменить.',
      );
    }
    final next = _bump(item);
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<ProfileFeedItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final next = _bump(current.copyWith(sortOrder: sortOrder));
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
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
    final idx = _indexOf(id);
    final current = _items[idx];
    if (!current.isDraft) {
      throw const ProfileFeedRepositoryException(
        'Аудиторию можно менять только у черновика.',
      );
    }
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final next = _bump(
      current.copyWith(
        audienceMode: audienceMode,
        audienceGroupIds: groupIds,
        audienceUserIds: userIds,
      ),
    );
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<ProfileFeedAudiencePreview> previewAudience(String id) async {
    final item = _items[_indexOf(id)];
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

  ProfileFeedItem _transition(
    String id,
    int expectedRowVersion,
    ProfileFeedItem Function(ProfileFeedItem) apply,
  ) {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final next = _bump(apply(current));
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<ProfileFeedItem> publish(String id, int expectedRowVersion) async {
    return _transition(id, expectedRowVersion, (item) {
      if (item.isArchived) {
        throw const ProfileFeedRepositoryException(
          'Архивную карточку нельзя опубликовать.',
        );
      }
      return item.copyWith(status: ProfileFeedStatus.published);
    });
  }

  @override
  Future<ProfileFeedItem> unpublish(String id, int expectedRowVersion) async {
    _assertNoWorkingDraft(id);
    return _transition(id, expectedRowVersion, (item) {
      if (item.isArchived) {
        throw const ProfileFeedRepositoryException(
          'Архивную карточку нельзя снять с публикации.',
        );
      }
      return item.copyWith(status: ProfileFeedStatus.draft);
    });
  }

  @override
  Future<ProfileFeedItem> archive(String id, int expectedRowVersion) async {
    _assertNoWorkingDraft(id);
    return _transition(
      id,
      expectedRowVersion,
      (item) => item.copyWith(status: ProfileFeedStatus.archived),
    );
  }

  @override
  Future<ProfileFeedItem> restoreArchived(
    String id,
    int expectedRowVersion,
  ) async {
    _assertNoWorkingDraft(id);
    return _transition(id, expectedRowVersion, (item) {
      if (!item.isArchived) {
        throw const ProfileFeedRepositoryException(
          'Восстановить можно только архивную карточку.',
        );
      }
      return item.copyWith(status: ProfileFeedStatus.draft);
    });
  }

  @override
  Future<ProfileFeedDeleteResult> safeDelete(
    String id,
    int expectedRowVersion,
  ) async {
    _assertNoWorkingDraft(id);
    final idx = _indexOf(id);
    final item = _items[idx];
    if (!item.isArchived) {
      throw const ProfileFeedRepositoryException(
        'Окончательное удаление доступно только для архивных карточек.',
      );
    }
    if (item.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    _items = [..._items]..removeAt(idx);
    _versions.remove(id);
    return ProfileFeedDeleteResult(id: id, legacyKey: item.legacyKey);
  }

  @override
  Future<ProfileFeedItem> duplicate(String id) async {
    final source = _items[_indexOf(id)];
    final copy = source.copyWith(
      id: 'local-profile-feed-${_seq++}',
      title: '${source.title} (копия)',
      status: ProfileFeedStatus.draft,
      origin: ContentOrigin.admin,
      sortOrder: _items.length,
      rowVersion: 1,
      versionNumber: 1,
      clearLegacyKey: true,
    );
    _items = [..._items, copy];
    _recordVersion(copy);
    return copy;
  }

  @override
  Future<ProfileFeedItem> promoteDemo(String id, int expectedRowVersion) async {
    return _transition(id, expectedRowVersion, (item) {
      if (item.origin != ContentOrigin.demo) {
        throw const ProfileFeedRepositoryException(
          'Продвижение доступно только для демо-карточек.',
        );
      }
      return item.copyWith(origin: ContentOrigin.admin);
    });
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
      final idx = _indexOf(orderedIds[i]);
      final current = _items[idx];
      if (current.rowVersion != expectedRowVersions[i]) {
        throw const ProfileFeedRepositoryException(
          'Карточка изменилась. Обновите список.',
        );
      }
      next.add(_bump(current.copyWith(sortOrder: i)));
    }
    for (var i = 0; i < next.length; i++) {
      final idx = _items.indexWhere((e) => e.id == next[i].id);
      if (idx >= 0) {
        _items[idx] = next[i];
        _recordVersion(next[i]);
      }
    }
  }

  @override
  Future<List<ProfileFeedVersionInfo>> listVersions(String id) async {
    _indexOf(id);
    final versions = _versions[id] ?? const <ProfileFeedItem>[];
    return [
      for (final item in versions.reversed)
        ProfileFeedVersionInfo(
          versionNumber: item.versionNumber,
          title: item.title,
          status: item.status,
        ),
    ];
  }

  @override
  Future<ProfileFeedItem> restoreVersion(
    String id,
    int versionNumber,
    int expectedRowVersion,
  ) async {
    final versions = _versions[id] ?? const <ProfileFeedItem>[];
    final match = versions.firstWhere(
      (item) => item.versionNumber == versionNumber,
      orElse: () =>
          throw const ProfileFeedRepositoryException('Версия не найдена.'),
    );
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Карточка изменилась. Обновите список.',
      );
    }
    final restored = _bump(
      match.copyWith(
        id: id,
        rowVersion: current.rowVersion,
        versionNumber: current.versionNumber,
      ),
    );
    _items = [..._items]..[idx] = restored;
    _recordVersion(restored);
    return restored;
  }

  @override
  Future<ProfileFeedItem> beginEdit(String id) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.isDraft) {
      throw const ProfileFeedRepositoryException(
        'Черновик редактируется напрямую.',
      );
    }
    if (current.isArchived) {
      throw const ProfileFeedRepositoryException(
        'Архивную карточку нельзя редактировать.',
      );
    }
    if (!_workingDrafts.containsKey(id)) {
      _workingDrafts[id] = _ProfileFeedWorkingDraft.fromItem(current);
    }
    return _withWorkingDraftOverlay(current);
  }

  @override
  Future<ProfileFeedItem> saveWorkingDraft(
    ProfileFeedItem item, {
    required int expectedDraftRowVersion,
  }) async {
    final current = _items[_indexOf(item.id)];
    final draft = _workingDrafts[item.id];
    if (draft == null) {
      throw const ProfileFeedRepositoryException(
        'Черновик изменений не найден.',
      );
    }
    if (draft.rowVersion != expectedDraftRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Черновик изменился. Обновите.',
      );
    }
    draft.apply(item);
    draft.rowVersion += 1;
    return _withWorkingDraftOverlay(current);
  }

  @override
  Future<ProfileFeedItem> publishWorkingDraft(
    String id, {
    required int expectedDraftRowVersion,
  }) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    final draft = _workingDrafts[id];
    if (draft == null) {
      throw const ProfileFeedRepositoryException(
        'Черновик изменений не найден.',
      );
    }
    if (draft.rowVersion != expectedDraftRowVersion) {
      throw const ProfileFeedRepositoryException(
        'Черновик изменился. Обновите.',
      );
    }
    final next = _bump(
      current.copyWith(
        title: draft.title,
        payload: draft.payload,
        priority: draft.priority,
        sortOrder: draft.sortOrder,
        audienceMode: draft.audienceMode,
        startsAt: draft.startsAt,
        endsAt: draft.endsAt,
        audienceGroupIds: draft.audienceGroupIds,
        audienceUserIds: draft.audienceUserIds,
        hasWorkingDraft: false,
        clearWorkingDraftRowVersion: true,
      ),
    );
    _items = [..._items]..[idx] = next;
    _workingDrafts.remove(id);
    _recordVersion(next);
    return next;
  }

  @override
  Future<ProfileFeedItem> discardWorkingDraft(String id) async {
    final current = _items[_indexOf(id)];
    _workingDrafts.remove(id);
    return current.copyWith(
      hasWorkingDraft: false,
      clearWorkingDraftRowVersion: true,
    );
  }
}

class _ProfileFeedWorkingDraft {
  _ProfileFeedWorkingDraft({
    required this.rowVersion,
    required this.title,
    required this.payload,
    required this.priority,
    required this.sortOrder,
    required this.audienceMode,
    required this.audienceGroupIds,
    required this.audienceUserIds,
    this.startsAt,
    this.endsAt,
  });

  factory _ProfileFeedWorkingDraft.fromItem(ProfileFeedItem item) {
    return _ProfileFeedWorkingDraft(
      rowVersion: 1,
      title: item.title,
      payload: item.payload,
      priority: item.priority,
      sortOrder: item.sortOrder,
      audienceMode: item.audienceMode,
      startsAt: item.startsAt,
      endsAt: item.endsAt,
      audienceGroupIds: List<String>.from(item.audienceGroupIds),
      audienceUserIds: List<String>.from(item.audienceUserIds),
    );
  }

  int rowVersion;
  String title;
  ProfileFeedPayload payload;
  int priority;
  int sortOrder;
  String audienceMode;
  DateTime? startsAt;
  DateTime? endsAt;
  List<String> audienceGroupIds;
  List<String> audienceUserIds;

  void apply(ProfileFeedItem item) {
    title = item.title;
    payload = item.payload;
    priority = item.priority;
    sortOrder = item.sortOrder;
    audienceMode = item.audienceMode;
    startsAt = item.startsAt;
    endsAt = item.endsAt;
    audienceGroupIds = List<String>.from(item.audienceGroupIds);
    audienceUserIds = List<String>.from(item.audienceUserIds);
  }
}
