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

  Future<HomePromoItem> publish(String id, int expectedRowVersion);

  Future<HomePromoItem> archive(String id, int expectedRowVersion);

  Future<void> reorder(List<String> orderedIds, List<int> expectedRowVersions);
}

class HomePromoRepositoryException implements Exception {
  const HomePromoRepositoryException(
    this.message, {
    this.isForbidden = false,
  });

  final String message;
  final bool isForbidden;

  @override
  String toString() => message;
}

/// In-memory demo repository for local prototype / offline Admin.
class LocalHomePromoRepository implements HomePromoRepository {
  LocalHomePromoRepository() {
    _items = [
      HomePromoItem(
        id: 'local-demo-home-promo',
        status: HomePromoStatus.published,
        origin: ContentOrigin.demo,
        title: HomePromoPayload.demoStuckWithAssignment.title,
        payload: HomePromoPayload.demoStuckWithAssignment,
        rowVersion: 1,
        priority: 0,
        sortOrder: 0,
        audienceMode: 'all',
      ),
    ];
  }

  late List<HomePromoItem> _items;
  int _seq = 1;

  @override
  Future<List<HomePromoItem>> list({String? status}) async {
    final filtered = status == null
        ? _items
        : _items
            .where((e) => homePromoStatusWire(e.status) == status)
            .toList();
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
    return item;
  }

  @override
  Future<HomePromoItem> updateDraft(HomePromoItem item) async {
    final idx = _items.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      throw const HomePromoRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.status != HomePromoStatus.draft) {
      throw const HomePromoRepositoryException(
        'Редактировать можно только черновик.',
      );
    }
    final next = item.copyWith(rowVersion: current.rowVersion + 1);
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<HomePromoItem> setPlacements({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const HomePromoRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException('Карточка изменилась. Обновите.');
    }
    final next = current.copyWith(
      sortOrder: sortOrder,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
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
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const HomePromoRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException('Карточка изменилась. Обновите.');
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
  Future<HomePromoItem> publish(String id, int expectedRowVersion) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const HomePromoRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException('Карточка изменилась. Обновите.');
    }
    final next = current.copyWith(
      status: HomePromoStatus.published,
      rowVersion: current.rowVersion + 1,
    );
    _items = [..._items]..[idx] = next;
    return next;
  }

  @override
  Future<HomePromoItem> archive(String id, int expectedRowVersion) async {
    final idx = _items.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const HomePromoRepositoryException('Карточка не найдена.');
    }
    final current = _items[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const HomePromoRepositoryException('Карточка изменилась. Обновите.');
    }
    final next = current.copyWith(
      status: HomePromoStatus.archived,
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
