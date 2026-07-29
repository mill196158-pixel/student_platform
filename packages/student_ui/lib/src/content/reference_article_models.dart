import 'package:flutter/material.dart';

import 'content_models.dart';

String? _readString(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }
  return null;
}

int? _readInt(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
  return null;
}

/// Reference section category (SoT: `reference_categories`).
@immutable
class ReferenceCategory {
  const ReferenceCategory({
    required this.id,
    required this.title,
    required this.iconKey,
    required this.sortOrder,
    this.key,
    this.status = 'published',
  });

  final String id;
  final String? key;
  final String title;
  final String iconKey;
  final int sortOrder;
  final String status;

  IconData get iconData => contentIconForKey(iconKey);

  static ReferenceCategory? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final id = _readString(json, const ['id']);
      final title = _readString(json, const ['title']);
      final iconKey = _readString(json, const ['icon_key', 'iconKey']);
      if (id == null || title == null || iconKey == null) return null;
      final sortOrder = _readInt(json, const ['sort_order', 'sortOrder']) ?? 0;
      final status = _readString(json, const ['status']) ?? 'published';
      if (status != 'published' && status != 'draft' && status != 'archived') {
        return null;
      }
      return ReferenceCategory(
        id: id,
        key: _readString(json, const ['key']),
        title: title,
        iconKey: iconKey,
        sortOrder: sortOrder,
        status: status,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toWireJson() => {
        'id': id,
        if (key != null) 'key': key,
        'title': title,
        'icon_key': iconKey,
        'sort_order': sortOrder,
        'status': status,
      };
}

/// Optional top-level CTA on reference articles.
@immutable
class ReferenceArticleCta {
  const ReferenceArticleCta({
    required this.label,
    this.route,
    this.url,
  });

  final String label;
  final String? route;
  final String? url;

  static ReferenceArticleCta? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final label = _readString(json, const ['label', 'cta_label', 'ctaLabel']);
    if (label == null) return null;
    final route = _readString(json, const ['route', 'cta_route', 'ctaRoute']);
    final url = _readString(json, const ['url', 'cta_url', 'ctaUrl']);
    if (route == null && url == null) return null;
    return ReferenceArticleCta(label: label, route: route, url: url);
  }

  Map<String, dynamic> toWireJson() => {
        'label': label,
        if (route != null) 'route': route,
        if (url != null) 'url': url,
      };
}

/// Typed content block for `reference_article_v1` (no HTML/JS).
sealed class ReferenceBlock {
  const ReferenceBlock();

  String get type;

  static ReferenceBlock? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final type = _readString(json, const ['type']);
    if (type == null) return null;
    switch (type) {
      case 'text':
        final text = _readString(json, const ['text', 'body']);
        if (text == null) return null;
        return ReferenceTextBlock(text: text);
      case 'image':
        final assetId = _readString(json, const [
          'asset_id',
          'assetId',
          'image_asset_id',
          'imageAssetId',
        ]);
        if (assetId == null) return null;
        return ReferenceImageBlock(
          assetId: assetId,
          caption: _readString(json, const ['caption']),
        );
      case 'file':
        final assetId = _readString(json, const ['asset_id', 'assetId']);
        if (assetId == null) return null;
        return ReferenceFileBlock(
          assetId: assetId,
          title: _readString(json, const ['title', 'label']),
        );
      case 'link':
        final label = _readString(json, const ['label', 'title']);
        final url = _readString(json, const ['url']);
        if (label == null || url == null) return null;
        if (!_isHttpsUrl(url)) return null;
        return ReferenceLinkBlock(label: label, url: url);
      case 'cta':
        final cta = ReferenceArticleCta.tryParse(json);
        if (cta == null) return null;
        return ReferenceCtaBlock(cta: cta);
      default:
        return null;
    }
  }

  Map<String, dynamic> toWireJson();

  static bool _isHttpsUrl(String raw) {
    final uri = Uri.tryParse(raw);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }
}

class ReferenceTextBlock extends ReferenceBlock {
  const ReferenceTextBlock({required this.text});

  final String text;

  /// Legacy alias retained for call sites that still use `body`.
  String get body => text;

  @override
  String get type => 'text';

  @override
  Map<String, dynamic> toWireJson() => {'type': type, 'text': text};
}

class ReferenceImageBlock extends ReferenceBlock {
  const ReferenceImageBlock({required this.assetId, this.caption});

  final String assetId;
  final String? caption;

  @override
  String get type => 'image';

  @override
  Map<String, dynamic> toWireJson() => {
        'type': type,
        'asset_id': assetId,
        if (caption != null) 'caption': caption,
      };
}

class ReferenceFileBlock extends ReferenceBlock {
  const ReferenceFileBlock({required this.assetId, this.title});

  final String assetId;
  final String? title;

  /// Legacy alias retained for call sites that still use `label`.
  String? get label => title;

  @override
  String get type => 'file';

  @override
  Map<String, dynamic> toWireJson() => {
        'type': type,
        'asset_id': assetId,
        if (title != null) 'title': title,
      };
}

class ReferenceLinkBlock extends ReferenceBlock {
  const ReferenceLinkBlock({required this.label, required this.url});

  final String label;
  final String url;

  @override
  String get type => 'link';

  @override
  Map<String, dynamic> toWireJson() => {
        'type': type,
        'label': label,
        'url': url,
      };
}

class ReferenceCtaBlock extends ReferenceBlock {
  const ReferenceCtaBlock({required this.cta});

  final ReferenceArticleCta cta;

  @override
  String get type => 'cta';

  @override
  Map<String, dynamic> toWireJson() => {'type': type, ...cta.toWireJson()};
}

/// Payload for template `reference_article_v1` (schema v1 legacy + v2 canonical).
@immutable
class ReferenceArticlePayload {
  const ReferenceArticlePayload({
    required this.iconKey,
    required this.shortText,
    required this.blocks,
    this.legacyCategory,
    this.cta,
  });

  final String iconKey;
  final String shortText;
  final List<ReferenceBlock> blocks;
  final String? legacyCategory;
  final ReferenceArticleCta? cta;

  IconData get iconData => contentIconForKey(iconKey);

  /// Fail-closed parser for schema v1 (requires legacy `category` string).
  static ReferenceArticlePayload? tryParseV1(Map<String, dynamic>? json) {
    if (json == null) return null;
    final category = _readString(json, const ['category']);
    if (category == null) return null;
    return _tryParseCore(json, legacyCategory: category);
  }

  /// Fail-closed parser for schema v2 (no client-controlled category field).
  static ReferenceArticlePayload? tryParseV2(Map<String, dynamic>? json) {
    if (json == null) return null;
    if (json.containsKey('category')) {
      final category = json['category'];
      if (category != null && category.toString().trim().isNotEmpty) {
        return null;
      }
    }
    return _tryParseCore(json);
  }

  static ReferenceArticlePayload? tryParseForSchema(
    int schemaVersion,
    Map<String, dynamic>? json,
  ) {
    return switch (schemaVersion) {
      1 => tryParseV1(json),
      2 => tryParseV2(json),
      _ => null,
    };
  }

  static ReferenceArticlePayload? _tryParseCore(
    Map<String, dynamic> json, {
    String? legacyCategory,
  }) {
    try {
      final iconKey = _readString(json, const ['icon_key', 'iconKey']);
      final shortText = _readString(json, const [
        'short_text',
        'shortText',
      ]);
      if (iconKey == null || shortText == null) return null;

      final blocksRaw = json['blocks'];
      if (blocksRaw is! List || blocksRaw.isEmpty) return null;
      final blocks = <ReferenceBlock>[];
      for (final item in blocksRaw) {
        if (item is! Map) return null;
        final block = ReferenceBlock.tryParse(Map<String, dynamic>.from(item));
        if (block == null) return null;
        blocks.add(block);
      }

      ReferenceArticleCta? cta;
      final flatCta = ReferenceArticleCta.tryParse(json);
      if (flatCta != null) {
        cta = flatCta;
      } else {
        final ctaRaw = json['cta'];
        if (ctaRaw != null) {
          if (ctaRaw is! Map) return null;
          cta = ReferenceArticleCta.tryParse(Map<String, dynamic>.from(ctaRaw));
          if (cta == null) return null;
        }
      }

      return ReferenceArticlePayload(
        iconKey: iconKey,
        shortText: shortText,
        blocks: blocks,
        legacyCategory: legacyCategory,
        cta: cta,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toWireJson({required int schemaVersion}) {
    final json = <String, dynamic>{
      'icon_key': iconKey,
      'short_text': shortText,
      'blocks': [for (final block in blocks) block.toWireJson()],
      if (cta != null) ...{
        'cta_label': cta!.label,
        if (cta!.route != null) 'cta_route': cta!.route,
        if (cta!.url != null) 'cta_url': cta!.url,
      },
    };
    if (schemaVersion == 1 && legacyCategory != null) {
      json['category'] = legacyCategory;
    }
    return json;
  }

  ReferenceArticlePayload copyWith({
    String? iconKey,
    String? shortText,
    List<ReferenceBlock>? blocks,
    String? legacyCategory,
    ReferenceArticleCta? cta,
    bool clearCta = false,
    bool clearLegacyCategory = false,
  }) {
    return ReferenceArticlePayload(
      iconKey: iconKey ?? this.iconKey,
      shortText: shortText ?? this.shortText,
      blocks: blocks ?? this.blocks,
      legacyCategory:
          clearLegacyCategory ? null : (legacyCategory ?? this.legacyCategory),
      cta: clearCta ? null : (cta ?? this.cta),
    );
  }
}

/// Managed reference article row from `get_my_reference_bundle`.
@immutable
class ManagedReferenceArticle {
  const ManagedReferenceArticle({
    required this.id,
    required this.title,
    required this.schemaVersion,
    required this.origin,
    required this.sortOrder,
    required this.categoryId,
    required this.categoryTitle,
    required this.payload,
    this.showDemoBadge = false,
  });

  final String id;
  final String title;
  final int schemaVersion;
  final ContentOrigin origin;
  final int sortOrder;
  final String categoryId;
  final String categoryTitle;
  final ReferenceArticlePayload payload;
  final bool showDemoBadge;

  bool get isManaged => origin != ContentOrigin.demo;

  static ManagedReferenceArticle? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final id = _readString(json, const ['id']);
      if (id == null) return null;

      final templateKey = _readString(json, const [
        'template_key',
        'templateKey',
      ]);
      if (templateKey != 'reference_article_v1') return null;

      final schemaVersion = _readInt(json, const [
        'schema_version',
        'schemaVersion',
      ]);
      if (schemaVersion == null || (schemaVersion != 1 && schemaVersion != 2)) {
        return null;
      }

      final origin = ContentOrigin.tryParse(json['origin']);
      if (origin == null) return null;

      final payloadRaw = json['payload'];
      if (payloadRaw is! Map) return null;
      final payload = ReferenceArticlePayload.tryParseForSchema(
        schemaVersion,
        Map<String, dynamic>.from(payloadRaw),
      );
      if (payload == null) return null;

      final categoryId = _readString(json, const [
        'category_id',
        'categoryId',
        'reference_category_id',
        'referenceCategoryId',
      ]);
      final categoryTitle = _readString(json, const [
        'category_title',
        'categoryTitle',
      ]);
      if (categoryId == null || categoryTitle == null) return null;

      final title = _readString(json, const ['title']) ?? payload.shortText;

      return ManagedReferenceArticle(
        id: id,
        title: title,
        schemaVersion: schemaVersion,
        origin: origin,
        sortOrder: _readInt(json, const ['sort_order', 'sortOrder']) ?? 0,
        categoryId: categoryId,
        categoryTitle: categoryTitle,
        payload: payload,
        showDemoBadge: origin == ContentOrigin.demo,
      );
    } catch (_) {
      return null;
    }
  }

  bool matchesQuery(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return categoryTitle.toLowerCase().contains(q) ||
        title.toLowerCase().contains(q) ||
        payload.shortText.toLowerCase().contains(q) ||
        payload.blocks.any((block) {
          return switch (block) {
            ReferenceTextBlock(:final text) => text.toLowerCase().contains(q),
            ReferenceLinkBlock(:final label) => label.toLowerCase().contains(q),
            ReferenceFileBlock(:final title) =>
              title?.toLowerCase().contains(q) ?? false,
            _ => false,
          };
        });
  }
}

/// Batched Mobile read model `{categories, articles}`.
@immutable
class ReferenceBundle {
  const ReferenceBundle({
    this.categories = const [],
    this.articles = const [],
  });

  final List<ReferenceCategory> categories;
  final List<ManagedReferenceArticle> articles;

  static ReferenceBundle? tryParse(dynamic raw) {
    dynamic value = raw;
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);

    final categoriesRaw = map['categories'];
    final articlesRaw = map['articles'];
    if (categoriesRaw is! List || articlesRaw is! List) return null;

    final categories = <ReferenceCategory>[];
    for (final row in categoriesRaw.whereType<Map>()) {
      final category = ReferenceCategory.tryParse(
        Map<String, dynamic>.from(row),
      );
      if (category == null) return null;
      categories.add(category);
    }

    final articles = <ManagedReferenceArticle>[];
    for (final row in articlesRaw.whereType<Map>()) {
      final article = ManagedReferenceArticle.tryParse(
        Map<String, dynamic>.from(row),
      );
      if (article == null) continue;
      articles.add(article);
    }

    return ReferenceBundle(categories: categories, articles: articles);
  }

  /// Legacy hardcoded help cards converted to labeled demo articles.
  static ReferenceBundle demoLegacyHelp() {
    const entries = <({
      String group,
      String iconKey,
      String title,
      String subtitle,
    })>[
      (
        group: 'Доступы',
        iconKey: 'login',
        title: 'Как зайти в личный кабинет',
        subtitle: 'Краткая инструкция по входу и восстановлению доступа.',
      ),
      (
        group: 'Доступы',
        iconKey: 'download',
        title: 'Как скачать нужные материалы',
        subtitle: 'Где искать файлы, методички и шаблоны.',
      ),
      (
        group: 'Документы',
        iconKey: 'description',
        title: 'Как заказать справку',
        subtitle: 'Основные действия для получения справки в университете.',
      ),
      (
        group: 'Программы',
        iconKey: 'computer',
        title: 'Как установить нужные программы',
        subtitle: 'AutoCAD, Revit, офисные программы и другое ПО.',
      ),
      (
        group: 'Карта и аудитории',
        iconKey: 'map',
        title: 'Карта и аудитории',
        subtitle: 'Как найти корпус, кабинет или аудиторию.',
      ),
      (
        group: 'Частые вопросы',
        iconKey: 'help',
        title: 'Частые вопросы',
        subtitle: 'Ответы на бытовые вопросы по учёбе.',
      ),
    ];

    final categoryIndex = <String, ReferenceCategory>{};
    final categories = <ReferenceCategory>[];
    final articles = <ManagedReferenceArticle>[];

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final categoryId = 'demo-cat-${entry.group.hashCode.abs()}';
      final category = categoryIndex.putIfAbsent(
        entry.group,
        () {
          final cat = ReferenceCategory(
            id: categoryId,
            key: entry.group.toLowerCase().replaceAll(' ', '_'),
            title: entry.group,
            iconKey: entry.iconKey,
            sortOrder: categories.length,
          );
          categories.add(cat);
          return cat;
        },
      );

      articles.add(
        ManagedReferenceArticle(
          id: 'demo-reference-$i',
          title: entry.title,
          schemaVersion: 1,
          origin: ContentOrigin.demo,
          sortOrder: i,
          categoryId: category.id,
          categoryTitle: category.title,
          payload: ReferenceArticlePayload(
            iconKey: entry.iconKey,
            shortText: entry.subtitle,
            legacyCategory: entry.group,
            blocks: [
              ReferenceTextBlock(text: entry.subtitle),
              const ReferenceTextBlock(
                text: 'Подробную инструкцию добавим в справочник.',
              ),
            ],
          ),
          showDemoBadge: true,
        ),
      );
    }

    return ReferenceBundle(categories: categories, articles: articles);
  }
}
