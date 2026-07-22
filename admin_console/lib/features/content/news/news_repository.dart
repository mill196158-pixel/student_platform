import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'news_item.dart';

/// News persistence boundary for the admin console.
///
/// [LocalNewsRepository] backs demo / local-prototype mode. The Supabase-backed
/// implementation lives in `supabase_news_repository.dart`. All mutations map to
/// RBAC-gated `SECURITY DEFINER` RPCs on the server.
abstract class NewsRepository {
  Future<List<NewsItem>> listNews();

  Future<NewsItem> createDraft({
    String title = '',
    String subtitle = '',
    String body = '',
    StudentHomeNewsVariant variant = StudentHomeNewsVariant.gradientText,
  });

  Future<NewsItem> updateDraft(NewsItem item);

  Future<NewsItem> publish(String id);

  Future<NewsItem> unpublish(String id);

  Future<NewsItem> archive(String id);

  Future<NewsItem> duplicate(String id);

  Future<void> reorder(List<String> orderedIds);

  Future<List<NewsVersionInfo>> listVersions(String id);

  Future<NewsItem> restoreVersion(String id, int versionNumber);

  /// Convenience alias used by the editor bootstrap and demo batches.
  Future<List<NewsItem>> loadDraft() => listNews();
}

/// Raised when a repository cannot fulfil a request (e.g. RBAC forbidden).
class NewsRepositoryException implements Exception {
  const NewsRepositoryException(this.message, {this.isForbidden = false});

  final String message;
  final bool isForbidden;

  @override
  String toString() => message;
}

class LocalNewsRepository implements NewsRepository {
  LocalNewsRepository({List<NewsItem>? seed}) {
    _items = seed != null ? List<NewsItem>.from(seed) : _defaultSeed();
    _nextId = _items.length + 1;
    for (final item in _items) {
      _versions[item.id] = [_snapshot(item)];
    }
  }

  late List<NewsItem> _items;
  late int _nextId;
  final Map<String, List<NewsItem>> _versions = {};

  static const _palette = <List<Color>>[
    [Color(0xFF7367F0), Color(0xFFB784F7)],
    [Color(0xFF246B8E), Color(0xFF54B7AD)],
    [Color(0xFFF3A95F), Color(0xFFE66E75)],
    [Color(0xFF4158D0), Color(0xFFC850C0)],
    [Color(0xFF2F9D84), Color(0xFF7C63D8)],
  ];

  static List<NewsItem> _defaultSeed() {
    return [
      const NewsItem(
        id: 'local-1',
        title: 'Добро пожаловать в новый семестр',
        subtitle: 'Всё важное для спокойного старта учёбы',
        body:
            'Главная стала полезнее: расписание, задания и подсказки под рукой.',
        variant: StudentHomeNewsVariant.gradientText,
        colors: [Color(0xFF7367F0), Color(0xFFB784F7)],
        status: NewsStatus.published,
        sortOrder: 0,
      ),
      const NewsItem(
        id: 'local-2',
        title: 'Неделя студенческих инициатив',
        subtitle: 'Выбирайте событие и присоединяйтесь',
        body:
            'На этой неделе пройдут встречи, мастер-классы и открытые лекции.',
        variant: StudentHomeNewsVariant.imageOverlay,
        colors: [Color(0xFF246B8E), Color(0xFF54B7AD)],
        overlayDarken: 0.48,
        status: NewsStatus.draft,
        sortOrder: 1,
      ),
      const NewsItem(
        id: 'local-3',
        title: 'Новые материалы по предметам',
        subtitle: 'Методички уже доступны в разделе «Полезная»',
        body: 'Добавлены новые методические материалы и примеры решений.',
        variant: StudentHomeNewsVariant.imageWithText,
        colors: [Color(0xFFF3A95F), Color(0xFFE66E75)],
        status: NewsStatus.draft,
        sortOrder: 2,
      ),
      const NewsItem(
        id: 'local-4',
        title: 'Студенческий кампус',
        subtitle: 'Фотогалерея июльских событий',
        body: 'Смотрите подборку фотографий с июльских мероприятий кампуса.',
        variant: StudentHomeNewsVariant.imageOnly,
        colors: [Color(0xFF4158D0), Color(0xFFC850C0)],
        status: NewsStatus.draft,
        sortOrder: 3,
      ),
    ];
  }

  NewsItem _snapshot(NewsItem item) => item;

  void _recordVersion(NewsItem item) {
    final list = _versions.putIfAbsent(item.id, () => []);
    list.add(_snapshot(item));
  }

  int _indexOf(String id) {
    final index = _items.indexWhere((item) => item.id == id);
    if (index < 0) {
      throw NewsRepositoryException('Новость не найдена.');
    }
    return index;
  }

  @override
  Future<List<NewsItem>> listNews() async {
    final sorted = List<NewsItem>.from(_items)
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        if (byOrder != 0) return byOrder;
        return b.priority.compareTo(a.priority);
      });
    return sorted;
  }

  @override
  Future<List<NewsItem>> loadDraft() => listNews();

  @override
  Future<NewsItem> createDraft({
    String title = '',
    String subtitle = '',
    String body = '',
    StudentHomeNewsVariant variant = StudentHomeNewsVariant.gradientText,
  }) async {
    final id = 'local-${_nextId++}';
    final now = DateTime.now();
    final item = NewsItem(
      id: id,
      title: title.isEmpty ? 'Новая новость' : title,
      subtitle: subtitle.isEmpty ? 'Краткое описание' : subtitle,
      body: body,
      variant: variant,
      colors: _palette[_items.length % _palette.length],
      status: NewsStatus.draft,
      sortOrder: _items.length,
      versionNumber: 1,
      createdAt: now,
      updatedAt: now,
    );
    _items.add(item);
    _recordVersion(item);
    return item;
  }

  @override
  Future<NewsItem> updateDraft(NewsItem item) async {
    final index = _indexOf(item.id);
    if (_items[index].isArchived) {
      throw const NewsRepositoryException('Архивную новость нельзя изменить.');
    }
    final updated = item.copyWith(
      versionNumber: _items[index].versionNumber + 1,
      updatedAt: DateTime.now(),
    );
    _items[index] = updated;
    _recordVersion(updated);
    return updated;
  }

  Future<NewsItem> _transition(
    String id,
    NewsItem Function(NewsItem) apply,
  ) async {
    final index = _indexOf(id);
    final updated = apply(_items[index]).copyWith(
      versionNumber: _items[index].versionNumber + 1,
      updatedAt: DateTime.now(),
    );
    _items[index] = updated;
    _recordVersion(updated);
    return updated;
  }

  @override
  Future<NewsItem> publish(String id) {
    return _transition(id, (item) {
      if (item.isArchived) {
        throw const NewsRepositoryException(
          'Архивную новость нельзя опубликовать.',
        );
      }
      return item.copyWith(
        status: NewsStatus.published,
        publishedAt: item.publishedAt ?? DateTime.now(),
      );
    });
  }

  @override
  Future<NewsItem> unpublish(String id) {
    return _transition(id, (item) => item.copyWith(status: NewsStatus.draft));
  }

  @override
  Future<NewsItem> archive(String id) {
    return _transition(
      id,
      (item) => item.copyWith(status: NewsStatus.archived),
    );
  }

  @override
  Future<NewsItem> duplicate(String id) async {
    final source = _items[_indexOf(id)];
    final newId = 'local-${_nextId++}';
    final now = DateTime.now();
    final copy = source.copyWith(
      id: newId,
      title: '${source.title} (копия)',
      status: NewsStatus.draft,
      sortOrder: _items.length,
      versionNumber: 1,
      publishedAt: null,
      createdAt: now,
      updatedAt: now,
    );
    _items.add(copy);
    _recordVersion(copy);
    return copy;
  }

  @override
  Future<void> reorder(List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      final index = _items.indexWhere((item) => item.id == orderedIds[i]);
      if (index >= 0) {
        _items[index] = _items[index].copyWith(sortOrder: i);
      }
    }
  }

  @override
  Future<List<NewsVersionInfo>> listVersions(String id) async {
    final versions = _versions[id] ?? const <NewsItem>[];
    return [
      for (final item in versions.reversed)
        NewsVersionInfo(
          versionNumber: item.versionNumber,
          createdAt: item.updatedAt ?? item.createdAt,
          title: item.title,
          status: item.status,
        ),
    ];
  }

  @override
  Future<NewsItem> restoreVersion(String id, int versionNumber) async {
    final versions = _versions[id] ?? const <NewsItem>[];
    final match = versions.firstWhere(
      (item) => item.versionNumber == versionNumber,
      orElse: () => throw const NewsRepositoryException('Версия не найдена.'),
    );
    final index = _indexOf(id);
    final restored = match.copyWith(
      versionNumber: _items[index].versionNumber + 1,
      updatedAt: DateTime.now(),
    );
    _items[index] = restored;
    _recordVersion(restored);
    return restored;
  }
}
