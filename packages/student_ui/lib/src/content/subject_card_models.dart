/// Stage 16.1 subject card typed models (shared Mobile / Admin Preview).
///
/// Fail-closed parsers. No HTML/JS. Name is never an identity key.

/// Fixed section-order allowlist (SPEC §16.1). Order = default order.
const List<String> kSubjectCardSectionAllowlist = [
  'short_description',
  'description',
  'learning_outcomes',
  'what_to_expect',
  'how_to_pass',
  'requirements',
  'useful_materials_note',
  'useful_links',
  'common_pitfalls',
  'teachers',
  'hours_credits',
  'relevance_date',
  'teacher_specific_note',
  'assessment_note',
  'workload_note',
];

/// Normalizes section_order.
///
/// Fail-closed: returns null if [raw] is a non-list non-null value, contains
/// unknown keys, or duplicates. Null/empty list → default allowlist order.
/// Omitted valid keys are appended in default order.
List<String>? tryNormalizeSubjectCardSectionOrder(Object? raw) {
  if (raw == null) return List<String>.from(kSubjectCardSectionAllowlist);
  if (raw is! List) return null;
  final seen = <String>{};
  final out = <String>[];
  for (final item in raw) {
    if (item is! String) return null;
    final key = item.trim();
    if (key.isEmpty) return null;
    if (!kSubjectCardSectionAllowlist.contains(key)) return null;
    if (!seen.add(key)) return null;
    out.add(key);
  }
  for (final key in kSubjectCardSectionAllowlist) {
    if (seen.add(key)) out.add(key);
  }
  return out;
}

/// Convenience for UI defaults (never throws; empty/null → default order).
List<String> normalizeSubjectCardSectionOrder(Object? raw) {
  return tryNormalizeSubjectCardSectionOrder(raw) ??
      List<String>.from(kSubjectCardSectionAllowlist);
}

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

num? _readNum(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is num) return value;
    return num.tryParse(value.toString());
  }
  return null;
}

/// Subject file descriptor (Stage 16.2). Never includes storage paths/URLs.
enum SubjectCardAssetKind {
  heroImage,
  attachment;

  static SubjectCardAssetKind? tryParse(Object? raw) {
    final value = raw?.toString().trim();
    return switch (value) {
      'hero_image' => SubjectCardAssetKind.heroImage,
      'attachment' => SubjectCardAssetKind.attachment,
      _ => null,
    };
  }

  String get wireValue => switch (this) {
        SubjectCardAssetKind.heroImage => 'hero_image',
        SubjectCardAssetKind.attachment => 'attachment',
      };
}

class SubjectCardAsset {
  const SubjectCardAsset({
    required this.id,
    required this.title,
    required this.mimeType,
    required this.byteSize,
    required this.versionNumber,
    required this.kind,
    required this.logicalAssetId,
  });

  final String id;
  final String title;
  final String mimeType;
  final int byteSize;
  final int versionNumber;
  final SubjectCardAssetKind kind;
  final String logicalAssetId;

  bool get isImage => mimeType.startsWith('image/');
  bool get isPdf => mimeType == 'application/pdf';

  static SubjectCardAsset? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final id = _readString(json, const ['id']);
      final mime = _readString(json, const ['mime_type', 'mimeType']);
      final logical = _readString(json, const [
        'logical_asset_id',
        'logicalAssetId',
      ]);
      final kind = SubjectCardAssetKind.tryParse(
        json['asset_kind'] ?? json['assetKind'],
      );
      if (id == null || mime == null || logical == null || kind == null) {
        return null;
      }
      final byteSize = _readInt(json, const ['byte_size', 'byteSize']);
      final version = _readInt(json, const ['version_number', 'versionNumber']);
      if (byteSize == null || byteSize < 0 || version == null || version < 1) {
        return null;
      }
      return SubjectCardAsset(
        id: id,
        title: _readString(json, const ['title']) ?? '',
        mimeType: mime,
        byteSize: byteSize,
        versionNumber: version,
        kind: kind,
        logicalAssetId: logical,
      );
    } catch (_) {
      return null;
    }
  }
}

int? _readInt(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }
  return null;
}

/// Asset descriptors for one owner scope (catalog or offering).
class SubjectCardAssetsScope {
  const SubjectCardAssetsScope({
    this.heroImage,
    this.attachments = const [],
  });

  const SubjectCardAssetsScope.empty()
      : heroImage = null,
        attachments = const [];

  final SubjectCardAsset? heroImage;
  final List<SubjectCardAsset> attachments;

  static SubjectCardAssetsScope? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    SubjectCardAsset? hero;
    final heroRaw = json['hero_image'] ?? json['heroImage'];
    if (heroRaw is Map) {
      hero = SubjectCardAsset.tryParse(Map<String, dynamic>.from(heroRaw));
    } else if (heroRaw != null) {
      return null;
    }
    final attachments = <SubjectCardAsset>[];
    final listRaw = json['attachments'];
    if (listRaw is List) {
      for (final row in listRaw.whereType<Map>()) {
        final asset = SubjectCardAsset.tryParse(
          Map<String, dynamic>.from(row),
        );
        if (asset == null) return null;
        attachments.add(asset);
      }
    } else if (listRaw != null) {
      return null;
    }
    return SubjectCardAssetsScope(heroImage: hero, attachments: attachments);
  }
}

/// Catalog + offering asset bundle from [get_subject_card].
class SubjectCardAssets {
  const SubjectCardAssets({
    this.catalog = const SubjectCardAssetsScope.empty(),
    this.offering = const SubjectCardAssetsScope.empty(),
  });

  final SubjectCardAssetsScope catalog;
  final SubjectCardAssetsScope offering;

  /// Effective student-facing descriptors (offering hero overrides catalog).
  SubjectCardAssetsScope get mergedForDisplay {
    return SubjectCardAssetsScope(
      heroImage: offering.heroImage ?? catalog.heroImage,
      attachments: [
        ...catalog.attachments,
        ...offering.attachments,
      ],
    );
  }

  static SubjectCardAssets? tryParse(Object? raw) {
    if (raw == null) return const SubjectCardAssets();
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final catalogRaw = json['catalog'];
    final offeringRaw = json['offering'];
    if (catalogRaw == null && offeringRaw == null) {
      final flat = SubjectCardAssetsScope.tryParse(json);
      if (flat == null) return null;
      return SubjectCardAssets(catalog: flat);
    }
    final catalog = catalogRaw is Map
        ? SubjectCardAssetsScope.tryParse(
            Map<String, dynamic>.from(catalogRaw),
          )
        : const SubjectCardAssetsScope.empty();
    if (catalogRaw is Map && catalog == null) return null;
    final offering = offeringRaw is Map
        ? SubjectCardAssetsScope.tryParse(
            Map<String, dynamic>.from(offeringRaw),
          )
        : const SubjectCardAssetsScope.empty();
    if (offeringRaw is Map && offering == null) return null;
    return SubjectCardAssets(
      catalog: catalog ?? const SubjectCardAssetsScope.empty(),
      offering: offering ?? const SubjectCardAssetsScope.empty(),
    );
  }
}

/// Merged student-facing subject card payload.
class SubjectCardPayload {
  const SubjectCardPayload({
    required this.subjectId,
    required this.canonicalName,
    required this.sectionOrder,
    this.subjectOfferingId,
    this.shortDescription,
    this.description,
    this.learningOutcomes,
    this.whatToExpect,
    this.howToPass,
    this.requirements,
    this.usefulMaterialsNote,
    this.commonPitfalls,
    this.controlForm,
    this.department,
    this.hoursTotal,
    this.credits,
    this.hoursCreditsAvailable = false,
    this.relevanceDate,
    this.usefulLinks = const [],
    this.teachers = const [],
    this.teacherSpecificNote,
    this.assessmentNote,
    this.workloadNote,
    this.assets = const SubjectCardAssets(),
  });

  final String subjectId;
  final String? subjectOfferingId;
  final String canonicalName;
  final List<String> sectionOrder;
  final String? shortDescription;
  final String? description;
  final String? learningOutcomes;
  final String? whatToExpect;
  final String? howToPass;
  final String? requirements;
  final String? usefulMaterialsNote;
  final String? commonPitfalls;
  final String? controlForm;
  final String? department;
  final num? hoursTotal;
  final num? credits;
  final bool hoursCreditsAvailable;
  final DateTime? relevanceDate;
  final List<SubjectCardLink> usefulLinks;
  final List<SubjectCardTeacher> teachers;
  final String? teacherSpecificNote;
  final String? assessmentNote;
  final String? workloadNote;
  final SubjectCardAssets assets;

  /// Convenience: merged hero + attachments for UI (metadata only).
  SubjectCardAssetsScope get displayAssets => assets.mergedForDisplay;

  /// Fail-closed: requires subject_id + non-empty canonical_name.
  static SubjectCardPayload? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final subjectId = _readString(json, const [
        'subject_id',
        'subjectId',
        'id',
      ]);
      final name = _readString(json, const [
        'canonical_name',
        'canonicalName',
        'title',
      ]);
      if (subjectId == null || name == null) return null;

      final linksRaw = json['useful_links'] ?? json['usefulLinks'];
      final links = <SubjectCardLink>[];
      if (linksRaw is List) {
        for (final row in linksRaw.whereType<Map>()) {
          final link = SubjectCardLink.tryParse(
            Map<String, dynamic>.from(row),
          );
          if (link != null) links.add(link);
        }
      }

      final teachersRaw = json['teachers'] ?? json['related_teachers'];
      final teachers = <SubjectCardTeacher>[];
      if (teachersRaw is List) {
        for (final row in teachersRaw.whereType<Map>()) {
          final t = SubjectCardTeacher.tryParse(
            Map<String, dynamic>.from(row),
          );
          if (t != null) teachers.add(t);
        }
      }

      DateTime? relevance;
      final relevanceRaw = json['relevance_date'] ?? json['relevanceDate'];
      if (relevanceRaw != null) {
        relevance = DateTime.tryParse(relevanceRaw.toString());
      }

      final hours = _readNum(json, const ['hours_total', 'hoursTotal']);
      final credits = _readNum(json, const ['credits']);
      final hoursAvailable = json['hours_credits_available'] == true ||
          json['hoursCreditsAvailable'] == true ||
          (hours != null || credits != null);

      final sectionOrder = tryNormalizeSubjectCardSectionOrder(
        json['section_order'] ?? json['sectionOrder'],
      );
      if (sectionOrder == null) return null;

      final assetsParsed = SubjectCardAssets.tryParse(json['assets']);
      if (json['assets'] != null && assetsParsed == null) return null;

      return SubjectCardPayload(
        subjectId: subjectId,
        subjectOfferingId: _readString(json, const [
          'subject_offering_id',
          'subjectOfferingId',
        ]),
        canonicalName: name,
        sectionOrder: sectionOrder,
        shortDescription: _readString(json, const [
          'short_description',
          'shortDescription',
        ]),
        description: _readString(json, const ['description']),
        learningOutcomes: _readString(json, const [
          'learning_outcomes',
          'learningOutcomes',
        ]),
        whatToExpect: _readString(json, const [
          'what_to_expect',
          'whatToExpect',
        ]),
        howToPass: _readString(json, const ['how_to_pass', 'howToPass']),
        requirements: _readString(json, const ['requirements']),
        usefulMaterialsNote: _readString(json, const [
          'useful_materials_note',
          'usefulMaterialsNote',
        ]),
        commonPitfalls: _readString(json, const [
          'common_pitfalls',
          'commonPitfalls',
        ]),
        controlForm: _readString(json, const [
          'control_form',
          'controlForm',
        ]),
        department: _readString(json, const ['department']),
        hoursTotal: hours,
        credits: credits,
        hoursCreditsAvailable: hoursAvailable,
        relevanceDate: relevance,
        usefulLinks: links,
        teachers: teachers,
        teacherSpecificNote: _readString(json, const [
          'teacher_specific_note',
          'teacherSpecificNote',
        ]),
        assessmentNote: _readString(json, const [
          'assessment_note',
          'assessmentNote',
        ]),
        workloadNote: _readString(json, const [
          'workload_note',
          'workloadNote',
        ]),
        assets: assetsParsed ?? const SubjectCardAssets(),
      );
    } catch (_) {
      return null;
    }
  }

  String? textForSection(String key) {
    switch (key) {
      case 'short_description':
        return shortDescription;
      case 'description':
        return description;
      case 'learning_outcomes':
        return learningOutcomes;
      case 'what_to_expect':
        return whatToExpect;
      case 'how_to_pass':
        return howToPass;
      case 'requirements':
        return requirements;
      case 'useful_materials_note':
        return usefulMaterialsNote;
      case 'common_pitfalls':
        return commonPitfalls;
      case 'teacher_specific_note':
        return teacherSpecificNote;
      case 'assessment_note':
        return assessmentNote;
      case 'workload_note':
        return workloadNote;
      default:
        return null;
    }
  }

  static String sectionTitleRu(String key) {
    switch (key) {
      case 'short_description':
        return 'Кратко';
      case 'description':
        return 'Описание';
      case 'learning_outcomes':
        return 'Чему научится студент';
      case 'what_to_expect':
        return 'Чего ожидать';
      case 'how_to_pass':
        return 'Советы по подготовке';
      case 'requirements':
        return 'Требования';
      case 'useful_materials_note':
        return 'Полезные материалы';
      case 'useful_links':
        return 'Ссылки';
      case 'common_pitfalls':
        return 'Типичные ошибки';
      case 'teachers':
        return 'Преподаватели';
      case 'hours_credits':
        return 'Часы и ЗЕ';
      case 'relevance_date':
        return 'Актуальность';
      case 'teacher_specific_note':
        return 'Заметка о преподавателе';
      case 'assessment_note':
        return 'Оценивание (offering)';
      case 'workload_note':
        return 'Нагрузка (offering)';
      default:
        return key;
    }
  }
}

class SubjectCardLink {
  const SubjectCardLink({required this.title, required this.url});

  final String title;
  final String url;

  static SubjectCardLink? tryParse(Map<String, dynamic> json) {
    final url = _readString(json, const ['url', 'href']);
    if (url == null) return null;
    if (!(url.startsWith('https://') || url.startsWith('http://'))) {
      return null;
    }
    final title = _readString(json, const ['title', 'label']) ?? url;
    return SubjectCardLink(title: title, url: url);
  }
}

class SubjectCardTeacher {
  const SubjectCardTeacher({
    required this.id,
    required this.displayName,
  });

  final String id;
  final String displayName;

  static SubjectCardTeacher? tryParse(Map<String, dynamic> json) {
    final id = _readString(json, const ['id', 'teacher_id', 'teacherId']);
    if (id == null) return null;
    final name = _readString(json, const [
          'full_name',
          'fullName',
          'display_name',
          'displayName',
          'name',
        ]) ??
        'Преподаватель';
    return SubjectCardTeacher(id: id, displayName: name);
  }
}
