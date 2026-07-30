import 'package:student_ui/student_ui.dart';

import 'reference_item.dart';

class ReferenceAudiencePreview {
  const ReferenceAudiencePreview({
    required this.recipientCount,
    required this.audienceMode,
    this.groupCount = 0,
    this.explicitUserCount = 0,
  });

  final int recipientCount;
  final String audienceMode;
  final int groupCount;
  final int explicitUserCount;

  factory ReferenceAudiencePreview.fromJson(Map<String, dynamic> json) {
    return ReferenceAudiencePreview(
      recipientCount: int.tryParse('${json['recipient_count'] ?? 0}') ?? 0,
      audienceMode: (json['audience_mode'] ?? 'all').toString(),
      groupCount: int.tryParse('${json['group_count'] ?? 0}') ?? 0,
      explicitUserCount:
          int.tryParse('${json['explicit_users_count'] ?? 0}') ?? 0,
    );
  }
}

abstract class ReferenceRepository {
  Future<List<ReferenceCategoryItem>> listCategories();

  Future<List<ReferenceArticleItem>> listArticles({String? status});

  Future<ReferenceCategoryItem> upsertCategory(ReferenceCategoryItem item);

  Future<void> reorderCategories(
    List<String> orderedIds,
    List<int> expectedRowVersions,
  );

  Future<ReferenceArticleItem> createArticleDraft({
    required String title,
    required ReferenceArticlePayload payload,
    required String categoryId,
    ContentOrigin origin = ContentOrigin.admin,
  });

  Future<ReferenceArticleItem> updateArticleDraft(ReferenceArticleItem item);

  Future<ReferenceArticleItem> setArticleSortOrder({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  });

  Future<ReferenceArticleItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  });

  Future<ReferenceAudiencePreview> previewAudience(String id);

  Future<ReferenceArticleItem> publish(String id, int expectedRowVersion);

  Future<ReferenceArticleItem> unpublish(String id, int expectedRowVersion);

  Future<ReferenceArticleItem> archive(String id, int expectedRowVersion);

  Future<ReferenceArticleItem> unarchive(String id, int expectedRowVersion);

  /// Permanently deletes an archived item and preserves its legacy tombstone.
  Future<void> safeDelete(String id, int expectedRowVersion);

  /// Converts an existing demo item to managed content; it never creates a copy.
  Future<ReferenceArticleItem> promoteDemo(String id, int expectedRowVersion);

  Future<List<ReferenceVersionInfo>> listVersions(String id);

  Future<ReferenceArticleItem> restoreVersion(
    String id,
    int versionNumber,
    int expectedRowVersion,
  );

  Future<List<ReferenceCorrectionItem>> listCorrections({
    String status = 'open',
  });

  Future<void> resolveCorrection({
    required String id,
    required String action,
    String reason = '',
  });
}

class ReferenceVersionInfo {
  const ReferenceVersionInfo({
    required this.versionNumber,
    required this.title,
    required this.status,
  });

  final int versionNumber;
  final String title;
  final ReferenceArticleStatus status;

  factory ReferenceVersionInfo.fromJson(Map<String, dynamic> json) {
    final snapshot = json['snapshot'];
    final data = snapshot is Map ? Map<String, dynamic>.from(snapshot) : json;
    return ReferenceVersionInfo(
      versionNumber: int.tryParse('${json['version_number'] ?? 0}') ?? 0,
      title: '${data['title'] ?? ''}',
      status:
          parseReferenceArticleStatus(data['status']) ??
          ReferenceArticleStatus.draft,
    );
  }
}

class ReferenceRepositoryException implements Exception {
  const ReferenceRepositoryException(this.message, {this.isForbidden = false});

  final String message;
  final bool isForbidden;

  @override
  String toString() => message;
}

/// In-memory repository for local prototype / widget tests.
class LocalReferenceRepository implements ReferenceRepository {
  LocalReferenceRepository() {
    final demo = ReferenceBundle.demoLegacyHelp();
    _categories = [
      for (final category in demo.categories)
        ReferenceCategoryItem(
          id: category.id,
          key: category.key,
          title: category.title,
          iconKey: category.iconKey,
          sortOrder: category.sortOrder,
          rowVersion: 1,
        ),
    ];
    _articles = [
      for (final article in demo.articles)
        ReferenceArticleItem(
          id: article.id,
          status: ReferenceArticleStatus.published,
          origin: ContentOrigin.demo,
          title: article.title,
          payload: article.payload,
          categoryId: article.categoryId,
          categoryTitle: article.categoryTitle,
          rowVersion: 1,
          sortOrder: article.sortOrder,
          audienceMode: 'all',
          legacyKey:
              'content:reference_article:${_referenceLegacyKey(article.id)}',
        ),
    ];
  }

  late List<ReferenceCategoryItem> _categories;
  late List<ReferenceArticleItem> _articles;
  final List<ReferenceCorrectionItem> _corrections = [];
  int _seq = 1;

  @override
  Future<List<ReferenceCategoryItem>> listCategories() async {
    final copy = [..._categories]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return copy;
  }

  @override
  Future<List<ReferenceArticleItem>> listArticles({String? status}) async {
    final filtered = status == null
        ? _articles
        : _articles
              .where((e) => referenceArticleStatusWire(e.status) == status)
              .toList();
    final copy = [...filtered]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return copy;
  }

  @override
  Future<ReferenceCategoryItem> upsertCategory(
    ReferenceCategoryItem item,
  ) async {
    final idx = _categories.indexWhere((e) => e.id == item.id);
    if (idx >= 0) {
      final next = item.copyWith(rowVersion: _categories[idx].rowVersion + 1);
      _categories = [..._categories]..[idx] = next;
      return next;
    }
    final created = item.id.isEmpty
        ? ReferenceCategoryItem(
            id: 'local-cat-${_seq++}',
            key: item.key,
            title: item.title,
            iconKey: item.iconKey,
            sortOrder: item.sortOrder,
            rowVersion: 1,
            status: item.status,
          )
        : item;
    _categories = [..._categories, created];
    return created;
  }

  @override
  Future<void> reorderCategories(
    List<String> orderedIds,
    List<int> expectedRowVersions,
  ) async {
    if (orderedIds.length != expectedRowVersions.length) {
      throw const ReferenceRepositoryException('Некорректный порядок.');
    }
    final next = <ReferenceCategoryItem>[];
    for (var i = 0; i < orderedIds.length; i++) {
      final idx = _categories.indexWhere((e) => e.id == orderedIds[i]);
      if (idx < 0) {
        throw const ReferenceRepositoryException('Категория не найдена.');
      }
      final current = _categories[idx];
      if (current.rowVersion != expectedRowVersions[i]) {
        throw const ReferenceRepositoryException(
          'Категория изменилась. Обновите список.',
        );
      }
      next.add(
        current.copyWith(sortOrder: i, rowVersion: current.rowVersion + 1),
      );
    }
    _categories = next;
  }

  @override
  Future<ReferenceArticleItem> createArticleDraft({
    required String title,
    required ReferenceArticlePayload payload,
    required String categoryId,
    ContentOrigin origin = ContentOrigin.admin,
  }) async {
    final item = ReferenceArticleItem(
      id: 'local-ref-${_seq++}',
      status: ReferenceArticleStatus.draft,
      origin: origin,
      title: title,
      payload: payload,
      categoryId: categoryId,
      rowVersion: 1,
      sortOrder: _articles.length,
      audienceMode: 'all',
    );
    _articles = [..._articles, item];
    return item;
  }

  @override
  Future<ReferenceArticleItem> updateArticleDraft(
    ReferenceArticleItem item,
  ) async {
    final idx = _articles.indexWhere((e) => e.id == item.id);
    if (idx < 0) {
      throw const ReferenceRepositoryException('Статья не найдена.');
    }
    final current = _articles[idx];
    if (current.status != ReferenceArticleStatus.draft) {
      throw const ReferenceRepositoryException(
        'Редактировать можно только черновик.',
      );
    }
    final next = item.copyWith(rowVersion: current.rowVersion + 1);
    _articles = [..._articles]..[idx] = next;
    return next;
  }

  @override
  Future<ReferenceArticleItem> setArticleSortOrder({
    required String id,
    required int sortOrder,
    required int expectedRowVersion,
  }) async {
    final idx = _articles.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ReferenceRepositoryException('Статья не найдена.');
    }
    final current = _articles[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ReferenceRepositoryException(
        'Статья изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      sortOrder: sortOrder,
      rowVersion: current.rowVersion + 1,
    );
    _articles = [..._articles]..[idx] = next;
    return next;
  }

  @override
  Future<ReferenceArticleItem> setAudience({
    required String id,
    required String audienceMode,
    required List<String> groupIds,
    required List<String> userIds,
    required int expectedRowVersion,
  }) async {
    final idx = _articles.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ReferenceRepositoryException('Статья не найдена.');
    }
    final current = _articles[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ReferenceRepositoryException(
        'Статья изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      audienceMode: audienceMode,
      audienceGroupIds: groupIds,
      audienceUserIds: userIds,
      rowVersion: current.rowVersion + 1,
    );
    _articles = [..._articles]..[idx] = next;
    return next;
  }

  @override
  Future<ReferenceAudiencePreview> previewAudience(String id) async {
    final idx = _articles.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ReferenceRepositoryException('Статья не найдена.');
    }
    final item = _articles[idx];
    return ReferenceAudiencePreview(
      recipientCount: item.audienceMode == 'all' ? 100 : 12,
      audienceMode: item.audienceMode,
      groupCount: item.audienceGroupIds.length,
      explicitUserCount: item.audienceUserIds.length,
    );
  }

  @override
  Future<ReferenceArticleItem> publish(
    String id,
    int expectedRowVersion,
  ) async {
    final idx = _articles.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ReferenceRepositoryException('Статья не найдена.');
    }
    final current = _articles[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ReferenceRepositoryException(
        'Статья изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      status: ReferenceArticleStatus.published,
      rowVersion: current.rowVersion + 1,
    );
    _articles = [..._articles]..[idx] = next;
    return next;
  }

  @override
  Future<ReferenceArticleItem> unpublish(String id, int expectedRowVersion) =>
      _transition(id, expectedRowVersion, ReferenceArticleStatus.draft);

  @override
  Future<ReferenceArticleItem> archive(
    String id,
    int expectedRowVersion,
  ) async {
    return _transition(id, expectedRowVersion, ReferenceArticleStatus.archived);
  }

  @override
  Future<ReferenceArticleItem> unarchive(String id, int expectedRowVersion) =>
      _transition(id, expectedRowVersion, ReferenceArticleStatus.draft);

  Future<ReferenceArticleItem> _transition(
    String id,
    int expectedRowVersion,
    ReferenceArticleStatus status,
  ) async {
    final idx = _articles.indexWhere((e) => e.id == id);
    if (idx < 0) {
      throw const ReferenceRepositoryException('Статья не найдена.');
    }
    final current = _articles[idx];
    if (current.rowVersion != expectedRowVersion) {
      throw const ReferenceRepositoryException(
        'Статья изменилась. Обновите список.',
      );
    }
    final next = current.copyWith(
      status: status,
      rowVersion: current.rowVersion + 1,
    );
    _articles = [..._articles]..[idx] = next;
    return next;
  }

  @override
  Future<void> safeDelete(String id, int expectedRowVersion) async {
    final idx = _articles.indexWhere((e) => e.id == id);
    if (idx < 0) throw const ReferenceRepositoryException('Статья не найдена.');
    final item = _articles[idx];
    if (item.rowVersion != expectedRowVersion) {
      throw const ReferenceRepositoryException(
        'Статья изменилась. Обновите список.',
      );
    }
    if (item.status != ReferenceArticleStatus.archived) {
      throw const ReferenceRepositoryException(
        'Удалять можно только статью из архива.',
      );
    }
    _articles = [..._articles]..removeAt(idx);
  }

  @override
  Future<ReferenceArticleItem> promoteDemo(
    String id,
    int expectedRowVersion,
  ) async {
    final idx = _articles.indexWhere((e) => e.id == id);
    if (idx < 0) throw const ReferenceRepositoryException('Статья не найдена.');
    final item = _articles[idx];
    if (item.rowVersion != expectedRowVersion) {
      throw const ReferenceRepositoryException(
        'Статья изменилась. Обновите список.',
      );
    }
    if (item.origin != ContentOrigin.demo) {
      throw const ReferenceRepositoryException(
        'Перевести можно только демо-статью.',
      );
    }
    final next = item.copyWith(
      origin: ContentOrigin.admin,
      rowVersion: item.rowVersion + 1,
    );
    _articles = [..._articles]..[idx] = next;
    return next;
  }

  @override
  Future<List<ReferenceVersionInfo>> listVersions(String id) async {
    final item = _articles.where((item) => item.id == id).firstOrNull;
    if (item == null)
      throw const ReferenceRepositoryException('Статья не найдена.');
    return [
      ReferenceVersionInfo(
        versionNumber: item.rowVersion,
        title: item.title,
        status: item.status,
      ),
    ];
  }

  @override
  Future<ReferenceArticleItem> restoreVersion(
    String id,
    int versionNumber,
    int expectedRowVersion,
  ) async {
    final item = _articles.where((item) => item.id == id).firstOrNull;
    if (item == null || versionNumber <= 0) {
      throw const ReferenceRepositoryException('Версия не найдена.');
    }
    if (item.rowVersion != expectedRowVersion) {
      throw const ReferenceRepositoryException(
        'Статья изменилась. Обновите список.',
      );
    }
    final restored = item.copyWith(rowVersion: item.rowVersion + 1);
    final idx = _articles.indexWhere((e) => e.id == id);
    _articles = [..._articles]..[idx] = restored;
    return restored;
  }

  @override
  Future<List<ReferenceCorrectionItem>> listCorrections({
    String status = 'open',
  }) async {
    return _corrections.where((c) => c.status == status).toList();
  }

  @override
  Future<void> resolveCorrection({
    required String id,
    required String action,
    String reason = '',
  }) async {
    final idx = _corrections.indexWhere((c) => c.id == id);
    if (idx < 0) {
      throw const ReferenceRepositoryException('Обращение не найдено.');
    }
    final current = _corrections[idx];
    _corrections[idx] = ReferenceCorrectionItem(
      id: current.id,
      contentItemId: current.contentItemId,
      contentTitle: current.contentTitle,
      note: current.note,
      status: action == 'resolve' ? 'resolved' : 'rejected',
      resolutionNote: reason.isEmpty ? null : reason,
      createdAt: current.createdAt,
    );
  }
}

String _referenceLegacyKey(String id) {
  const byDemoId = <String, String>{
    'demo-reference-0': 'login_cabinet',
    'demo-reference-1': 'download_materials',
    'demo-reference-2': 'order_certificate',
    'demo-reference-3': 'install_software',
    'demo-reference-4': 'campus_map',
    'demo-reference-5': 'faq',
  };
  return byDemoId[id] ?? id;
}
