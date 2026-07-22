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

  Future<NewsItem> getNews(String id);

  Future<NewsItem> createDraft({
    String title = '',
    String subtitle = '',
    String body = '',
    StudentHomeNewsVariant variant = StudentHomeNewsVariant.gradientText,
  });

  Future<NewsItem> updateDraft(
    NewsItem item, {
    NewsImagePathPatch imagePathPatch = NewsImagePathPatch.omit,
  });

  Future<NewsItem> publish(String id);

  Future<NewsItem> unpublish(String id);

  Future<NewsItem> archive(String id);

  /// Restores an archived post to [NewsStatus.draft].
  Future<NewsItem> restoreArchived(String id);

  /// Permanently deletes an archived post. Never deletes published/draft.
  Future<NewsDeleteResult> deleteArchived(String id);

  /// Records Storage cleanup failures for later retry (server-side queue).
  Future<void> recordMediaCleanupFailure({
    required List<String> paths,
    String? sourceNewsPostId,
    String? sourceTitle,
    String? errorText,
  });

  Future<NewsItem> duplicate(String id);

  Future<void> reorder(List<String> orderedIds);

  Future<List<NewsVersionInfo>> listVersions(String id);

  Future<NewsItem> restoreVersion(String id, int versionNumber);

  /// Convenience alias used by the editor bootstrap and demo batches.
  Future<List<NewsItem>> loadDraft() => listNews();
}

/// Result of [NewsRepository.deleteArchived].
class NewsDeleteResult {
  const NewsDeleteResult({
    required this.id,
    required this.title,
    this.previousStatus = NewsStatus.archived,
    this.candidateMediaPaths = const [],
    this.mediaPathsToDelete = const [],
  });

  final String id;
  final String title;
  final NewsStatus previousStatus;
  final List<String> candidateMediaPaths;

  /// Orphan paths the server has verified are safe to remove from Storage.
  final List<String> mediaPathsToDelete;
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
  final List<Map<String, dynamic>> pendingMediaCleanup = [];
  final List<Map<String, dynamic>> auditTombstones = [];

  /// Test helper: in-memory version snapshots for an id (empty after delete).
  List<NewsItem> versionsFor(String id) =>
      List<NewsItem>.from(_versions[id] ?? const <NewsItem>[]);

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
  Future<NewsItem> getNews(String id) async {
    return _items[_indexOf(id)];
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
  Future<NewsItem> updateDraft(
    NewsItem item, {
    NewsImagePathPatch imagePathPatch = NewsImagePathPatch.omit,
  }) async {
    final index = _indexOf(item.id);
    final previous = _items[index];
    if (previous.isArchived) {
      throw const NewsRepositoryException('Архивную новость нельзя изменить.');
    }
    final base = item.copyWith(
      versionNumber: previous.versionNumber + 1,
      updatedAt: DateTime.now(),
    );
    final updated = switch (imagePathPatch) {
      NewsImagePathPatch.omit => base.copyWith(imagePath: previous.imagePath),
      NewsImagePathPatch.set => base,
      NewsImagePathPatch.clear => base.copyWith(clearImagePath: true),
    };
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
  Future<NewsItem> restoreArchived(String id) {
    return _transition(id, (item) {
      if (!item.isArchived) {
        throw const NewsRepositoryException(
          'Удалять или восстанавливать можно только архивные новости.',
        );
      }
      return item.copyWith(status: NewsStatus.draft);
    });
  }

  Set<String> _pathsForItem(String id) {
    final paths = <String>{};
    final index = _items.indexWhere((e) => e.id == id);
    if (index >= 0) {
      final path = _items[index].imagePath;
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    for (final version in _versions[id] ?? const <NewsItem>[]) {
      final path = version.imagePath;
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    return paths;
  }

  bool _pathStillReferenced(String path, {required String excludingId}) {
    for (final item in _items) {
      if (item.id == excludingId) continue;
      if (item.imagePath == path) return true;
    }
    for (final entry in _versions.entries) {
      if (entry.key == excludingId) continue;
      for (final version in entry.value) {
        if (version.imagePath == path) return true;
      }
    }
    return false;
  }

  @override
  Future<NewsDeleteResult> deleteArchived(String id) async {
    final index = _indexOf(id);
    final item = _items[index];
    if (!item.isArchived) {
      throw const NewsRepositoryException(
        'Окончательное удаление доступно только для архивных новостей.',
      );
    }
    final candidates = _pathsForItem(id).toList();
    final toDelete = <String>[
      for (final path in candidates)
        if (!_pathStillReferenced(path, excludingId: id)) path,
    ];
    _items.removeAt(index);
    _versions.remove(id);
    auditTombstones.add({
      'id': id,
      'title': item.title,
      'previous_status': 'archived',
    });
    return NewsDeleteResult(
      id: id,
      title: item.title,
      previousStatus: NewsStatus.archived,
      candidateMediaPaths: candidates,
      mediaPathsToDelete: toDelete,
    );
  }

  @override
  Future<void> recordMediaCleanupFailure({
    required List<String> paths,
    String? sourceNewsPostId,
    String? sourceTitle,
    String? errorText,
  }) async {
    for (final path in paths) {
      if (path.trim().isEmpty) continue;
      if (_pathStillReferenced(path, excludingId: sourceNewsPostId ?? '')) {
        continue;
      }
      pendingMediaCleanup.add({
        'object_path': path,
        'source_news_post_id': sourceNewsPostId,
        'source_title': sourceTitle,
        'error_text': errorText ?? 'storage_cleanup_failed',
      });
    }
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
