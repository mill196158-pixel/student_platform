import 'package:student_ui/student_ui.dart';

import 'home_promo_item.dart';

abstract class HomePromoRepository {
  Future<List<HomePromoItem>> list({String? status});

  Future<HomePromoItem> createDraft({
    required HomePromoPayload payload,
    String? title,
    ContentOrigin origin = ContentOrigin.admin,
  });

  Future<HomePromoItem> updateDraft(HomePromoItem item);

  Future<HomePromoItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  });

  Future<HomePromoItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  });

  Future<HomePromoAudiencePreview> previewAudience(String id);

  Future<HomePromoItem> publish(String id, int expectedRowVersion);

  Future<HomePromoItem> unpublish(String id, int expectedRowVersion);

  Future<HomePromoItem> archive(String id, int expectedRowVersion);

  Future<HomePromoItem> restoreArchived(String id, int expectedRowVersion);

  Future<HomePromoSafeDeleteResult> safeDelete(
    String id,
    int expectedRowVersion,
  );

  Future<HomePromoItem> duplicate(String id);

  Future<HomePromoItem> promoteDemo(String id, int expectedRowVersion);

  Future<List<HomePromoVersionInfo>> listVersions(String id);

  Future<HomePromoItem> restoreVersion(String id, int versionNumber);

  Future<void> reorder(List<String> orderedIds, List<int> expectedRowVersions);
}

class HomePromoRepositoryException implements Exception {
  const HomePromoRepositoryException(this.message, {this.isForbidden = false});

  final String message;
  final bool isForbidden;

  @override
  String toString() => message;
}

/// In-memory demo repository for local prototype / offline Admin.
class LocalHomePromoRepository implements HomePromoRepository {
  LocalHomePromoRepository() {
    final demo = HomePromoItem(
      id: 'local-demo-home-promo',
      status: HomePromoStatus.published,
      origin: ContentOrigin.demo,
      title: HomePromoPayload.demoStuckWithAssignment.title,
      payload: HomePromoPayload.demoStuckWithAssignment,
      rowVersion: 1,
      priority: 0,
      sortOrder: 0,
      audienceMode: 'all',
      legacyKey: 'content:home_promo:stuck_with_assignment',
    );
    _items = [demo];
    _versions[demo.id] = [demo];
  }

  late List<HomePromoItem> _items;
  int _seq = 1;
  final Map<String, List<HomePromoItem>> _versions = {};

  void _recordVersion(HomePromoItem item) {
    final list = _versions.putIfAbsent(item.id, () => []);
    list.add(item);
  }

  int _indexOf(String id) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) {
      throw const HomePromoRepositoryException('Карточка не найдена.');
    }
    return index;
  }

  HomePromoItem _bump(HomePromoItem item, {HomePromoStatus? status}) {
    return item.copyWith(
      status: status ?? item.status,
      rowVersion: item.rowVersion + 1,
      versionNumber: item.versionNumber + 1,
    );
  }

  @override
  Future<List<HomePromoItem>> list({String? status}) async {
    final filtered = status == null
        ? _items
        : _items.where((e) => homePromoStatusWire(e.status) == status).toList();
    final copy = [...filtered]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return copy;
  }

  @override
  Future<HomePromoItem> createDraft({
    required HomePromoPayload payload,
    String? title,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final item = HomePromoItem(
      id: 'local-home-promo-${_seq++}',
      status: HomePromoStatus.draft,
      origin: origin,
      title: title ?? payload.title,
      payload: payload,
      rowVersion: 1,
      priority: 0,
      sortOrder: _items.length,
      audienceMode: 'all',
    );
    _items = [..._items, item];
    _recordVersion(item);
    return item;
  }

  @override
  Future<HomePromoItem> updateDraft(HomePromoItem item) async {
    final idx = _indexOf(item.id);
    final current = _items[idx];
    if (current.isArchived) {
      throw const HomePromoRepositoryException(
        'Архивную карточку нельзя изменить.',
      );
    }
    if (!current.isDraft) {
      throw const HomePromoRepositoryException(
        'Редактировать можно только черновик.',
      );
    }
    final next = item.copyWith(
      rowVersion: current.rowVersion + 1,
      versionNumber: current.versionNumber + 1,
    );
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<HomePromoItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    final next = current.copyWith(
      sortOrder: sortOrder,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<HomePromoItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  }) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (!current.isDraft) {
      throw const HomePromoRepositoryException(
        'Аудиторию можно менять только у черновика.',
      );
    }
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    final next = current.copyWith(
      audienceMode: audienceMode,
      audienceGroupIds: groupIds,
      audienceUserIds: userIds,
      rowVersion: current.rowVersion + 1,
      versionNumber: current.versionNumber + 1,
    );
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<HomePromoAudiencePreview> previewAudience(String id) async {
    final item = _items[_indexOf(id)];
    final count = switch (item.audienceMode) {
      'groups' => item.audienceGroupIds.length * 10,
      'users' => item.audienceUserIds.length,
      'groups_and_users' =>
        item.audienceGroupIds.length * 10 + item.audienceUserIds.length,
      _ => 100,
    };
    return HomePromoAudiencePreview(
      recipientCount: count,
      audienceMode: item.audienceMode,
      groupCount: item.audienceGroupIds.length,
      explicitUserCount: item.audienceUserIds.length,
    );
  }

  @override
  Future<HomePromoItem> publish(String id, int expectedRowVersion) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    if (current.isArchived) {
      throw const HomePromoRepositoryException(
        'Архивную карточку нельзя опубликовать.',
      );
    }
    final next = _bump(current, status: HomePromoStatus.published);
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<HomePromoItem> unpublish(String id, int expectedRowVersion) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    final next = _bump(current, status: HomePromoStatus.draft);
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<HomePromoItem> archive(String id, int expectedRowVersion) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    final next = _bump(current, status: HomePromoStatus.archived);
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<HomePromoItem> restoreArchived(
    String id,
    int expectedRowVersion,
  ) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    if (!current.isArchived) {
      throw const HomePromoRepositoryException(
        'Восстановить можно только архивную карточку.',
      );
    }
    final next = _bump(current, status: HomePromoStatus.draft);
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<HomePromoSafeDeleteResult> safeDelete(
    String id,
    int expectedRowVersion,
  ) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    if (!current.isArchived) {
      throw const HomePromoRepositoryException(
        'Окончательное удаление доступно только для архивных карточек.',
      );
    }
    _items = [..._items]..removeAt(idx);
    _versions.remove(id);
    return HomePromoSafeDeleteResult(id: id, legacyKey: current.legacyKey);
  }

  @override
  Future<HomePromoItem> duplicate(String id) async {
    final source = _items[_indexOf(id)];
    final copy = source.copyWith(
      id: 'local-home-promo-${_seq++}',
      title: 'Копия: ${source.title}',
      status: HomePromoStatus.draft,
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
  Future<HomePromoItem> promoteDemo(String id, int expectedRowVersion) async {
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException(
        'Карточка изменилась. Обновите.',
      );
    }
    if (current.origin != ContentOrigin.demo) {
      throw const HomePromoRepositoryException(
        'Продвижение доступно только для демо-карточек.',
      );
    }
    final next = _bump(
      current,
      status: current.status,
    ).copyWith(origin: ContentOrigin.admin);
    _items = [..._items]..[idx] = next;
    _recordVersion(next);
    return next;
  }

  @override
  Future<List<HomePromoVersionInfo>> listVersions(String id) async {
    final versions = _versions[id] ?? const <HomePromoItem>[];
    return [
      for (final item in versions.reversed)
        HomePromoVersionInfo(
          versionNumber: item.versionNumber,
          title: item.title,
          status: item.status,
        ),
    ];
  }

  @override
  Future<HomePromoItem> restoreVersion(String id, int versionNumber) async {
    final versions = _versions[id] ?? const <HomePromoItem>[];
    HomePromoItem? match;
    for (final item in versions) {
      if (item.versionNumber == versionNumber) {
        match = item;
        break;
      }
    }
    if (match == null) {
      throw const HomePromoRepositoryException('Версия не найдена.');
    }
    final idx = _indexOf(id);
    final current = _items[idx];
    if (current.isArchived) {
      throw const HomePromoRepositoryException(
        'Архивную карточку нельзя изменить.',
      );
    }
    final restored = match.copyWith(
      id: current.id,
      rowVersion: current.rowVersion + 1,
      versionNumber: current.versionNumber + 1,
      status: current.status,
      origin: current.origin,
      legacyKey: current.legacyKey,
    );
    _items = [..._items]..[idx] = restored;
    _recordVersion(restored);
    return restored;
  }

  @override
  Future<void> reorder(
    List<String> orderedIds,
    List<int> expectedRowVersions,
  ) async {
    if (orderedIds.length != expectedRowVersions.length) {
      throw const HomePromoRepositoryException('Некорректный порядок.');
    }
    for (var i = 0; i < orderedIds.length; i++) {
      await setPlacements(
        id: orderedIds[i],
        sortOrder: i,
        expectedRowVersion: expectedRowVersions[i],
      );
    }
  }
}
