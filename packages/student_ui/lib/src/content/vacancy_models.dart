import 'package:flutter/material.dart';



import 'content_models.dart';



/// Employment type wire values from `public.vacancies.employment_type`.

enum VacancyEmploymentType {

  internship,

  partTime,

  fullTime,

  project,

  volunteer;



  static VacancyEmploymentType? tryParse(Object? raw) {

    if (raw is! String) return null;

    switch (raw) {

      case 'internship':

        return VacancyEmploymentType.internship;

      case 'part_time':

        return VacancyEmploymentType.partTime;

      case 'full_time':

        return VacancyEmploymentType.fullTime;

      case 'project':

        return VacancyEmploymentType.project;

      case 'volunteer':

        return VacancyEmploymentType.volunteer;

      default:

        return null;

    }

  }



  String get wireValue {

    switch (this) {

      case VacancyEmploymentType.internship:

        return 'internship';

      case VacancyEmploymentType.partTime:

        return 'part_time';

      case VacancyEmploymentType.fullTime:

        return 'full_time';

      case VacancyEmploymentType.project:

        return 'project';

      case VacancyEmploymentType.volunteer:

        return 'volunteer';

    }

  }



  String get labelRu {

    switch (this) {

      case VacancyEmploymentType.internship:

        return 'Стажировка';

      case VacancyEmploymentType.partTime:

        return 'Подработка';

      case VacancyEmploymentType.fullTime:

        return 'Полная занятость';

      case VacancyEmploymentType.project:

        return 'Проект';

      case VacancyEmploymentType.volunteer:

        return 'Волонтёрство';

    }

  }

}



/// Work format wire values from `public.vacancies.work_format`.

enum VacancyWorkFormat {

  onsite,

  remote,

  hybrid;



  static VacancyWorkFormat? tryParse(Object? raw) {

    if (raw is! String) return null;

    switch (raw) {

      case 'onsite':

        return VacancyWorkFormat.onsite;

      case 'remote':

        return VacancyWorkFormat.remote;

      case 'hybrid':

        return VacancyWorkFormat.hybrid;

      default:

        return null;

    }

  }



  String get wireValue {

    switch (this) {

      case VacancyWorkFormat.onsite:

        return 'onsite';

      case VacancyWorkFormat.remote:

        return 'remote';

      case VacancyWorkFormat.hybrid:

        return 'hybrid';

    }

  }



  String get labelRu {

    switch (this) {

      case VacancyWorkFormat.onsite:

        return 'Офис';

      case VacancyWorkFormat.remote:

        return 'Удалённо';

      case VacancyWorkFormat.hybrid:

        return 'Гибрид';

    }

  }

}



/// Report reason codes for `report_vacancy`.

enum VacancyReportReason {

  spam,

  scam,

  abuse,

  outdated,

  privacy,

  other;



  String get wireValue {

    switch (this) {

      case VacancyReportReason.spam:

        return 'spam';

      case VacancyReportReason.scam:

        return 'scam';

      case VacancyReportReason.abuse:

        return 'abuse';

      case VacancyReportReason.outdated:

        return 'outdated';

      case VacancyReportReason.privacy:

        return 'privacy';

      case VacancyReportReason.other:

        return 'other';

    }

  }



  String get labelRu {

    switch (this) {

      case VacancyReportReason.spam:

        return 'Спам';

      case VacancyReportReason.scam:

        return 'Мошенничество';

      case VacancyReportReason.abuse:

        return 'Оскорбления';

      case VacancyReportReason.outdated:

        return 'Устарело';

      case VacancyReportReason.privacy:

        return 'Конфиденциальность';

      case VacancyReportReason.other:

        return 'Другое';

    }

  }

}



DateTime? _readDate(Object? raw) {

  if (raw == null) return null;

  return DateTime.tryParse(raw.toString());

}



bool? _readBool(Map<String, dynamic> json, String key) {

  final value = json[key];

  if (value == null) return null;

  if (value is bool) return value;

  return null;

}



List<String> _readIdList(Object? raw) {

  if (raw is! List) return const [];

  return raw

      .map((e) => e?.toString().trim() ?? '')

      .where((e) => e.isNotEmpty)

      .toList();

}



/// Marker separating main description from requirements (embedded in description).

const String vacancyRequirementsMarker = '\n\n---\nТребования:\n';



/// Attachment kind derived from vacancy asset MIME type.

enum VacancyAssetKind {

  image,

  pdf,

  other;



  static VacancyAssetKind fromMime(String mime) {

    final normalized = mime.trim().toLowerCase();

    if (normalized.startsWith('image/')) return VacancyAssetKind.image;

    if (normalized == 'application/pdf') return VacancyAssetKind.pdf;

    return VacancyAssetKind.other;

  }



  String get labelRu {

    switch (this) {

      case VacancyAssetKind.image:

        return 'Изображение';

      case VacancyAssetKind.pdf:

        return 'PDF';

      case VacancyAssetKind.other:

        return 'Вложение';

    }

  }

}



/// Typed mobile vacancy asset descriptor (`get_my_vacancies.assets` row).

@immutable

class VacancyAssetDescriptor {

  const VacancyAssetDescriptor({

    required this.id,

    required this.title,

    required this.mimeType,

  });



  final String id;

  final String title;

  final String mimeType;



  VacancyAssetKind get kind => VacancyAssetKind.fromMime(mimeType);



  String get displayLabel {

    final trimmed = title.trim();

    if (trimmed.isNotEmpty) return trimmed;

    return kind.labelRu;

  }



  static VacancyAssetDescriptor? tryParse(Map<String, dynamic>? json) {

    if (json == null) return null;

    try {

      final id = _readString(json, const ['id']);

      if (id == null) return null;

      final mime = _readString(json, const ['mime_type', 'mimeType']) ?? '';

      return VacancyAssetDescriptor(

        id: id,

        title: _readString(json, const ['title']) ?? '',

        mimeType: mime,

      );

    } catch (_) {

      return null;

    }

  }

}



List<VacancyAssetDescriptor> _readVacancyAssets(Object? raw) {

  if (raw is List) {

    final assets = <VacancyAssetDescriptor>[];

    for (final item in raw) {

      if (item is! Map) continue;

      final parsed = VacancyAssetDescriptor.tryParse(

        Map<String, dynamic>.from(item),

      );

      if (parsed != null) assets.add(parsed);

    }

    if (assets.isNotEmpty) return assets;

  }

  return _readIdList(raw)

      .map(

        (id) => VacancyAssetDescriptor(

          id: id,

          title: '',

          mimeType: '',

        ),

      )

      .toList();

}



/// Split full description wire value into body + requirements.

({String body, String requirements}) splitVacancyDescription(String description) {

  final idx = description.indexOf(vacancyRequirementsMarker);

  if (idx < 0) {

    return (body: description.trim(), requirements: '');

  }

  return (

    body: description.substring(0, idx).trim(),

    requirements: description.substring(idx + vacancyRequirementsMarker.length).trim(),

  );

}



/// Typed mobile vacancy card payload (flat `get_my_vacancies` row).

@immutable

class VacancyCardPayload {

  const VacancyCardPayload({

    required this.title,

    required this.companyName,

    required this.summary,

    this.descriptionFull,

    this.requirementsText,

    this.employmentType,

    this.workFormat,

    this.location,

    this.salaryText,

    this.externalUrl,

    this.tags = const [],

    this.accentColor = const Color(0xFF6A4BBC),

  });



  final String title;

  final String companyName;

  final String summary;

  final String? descriptionFull;

  final String? requirementsText;

  final VacancyEmploymentType? employmentType;

  final VacancyWorkFormat? workFormat;

  final String? location;

  final String? salaryText;

  final String? externalUrl;

  final List<String> tags;

  final Color accentColor;



  /// Built-in demo matching historic `_demoJobs` on Info screen.

  static const List<VacancyCardPayload> demoVacancies = [

    VacancyCardPayload(

      title: 'Junior Flutter Developer',

      companyName: 'Campus Lab',

      summary:

          'Помощь с мобильным приложением, простые экраны, фиксы UI и работа с наставником.',

      descriptionFull:

          'Помощь с мобильным приложением, простые экраны, фиксы UI и работа с наставником.',

      requirementsText: 'Базовый Flutter, аккуратность, желание учиться.',

      employmentType: VacancyEmploymentType.internship,

      workFormat: VacancyWorkFormat.hybrid,

      location: 'Гибрид',

      salaryText: 'от 35 000 ₽',

      tags: ['Flutter', 'Dart', 'UI'],

      accentColor: Color(0xFF6A4BBC),

    ),

    VacancyCardPayload(

      title: 'Ассистент преподавателя по программированию',

      companyName: 'Кафедра ИТ',

      summary:

          'Проверка лабораторных, помощь первокурсникам и подготовка коротких материалов.',

      descriptionFull:

          'Проверка лабораторных, помощь первокурсникам и подготовка коротких материалов.',

      employmentType: VacancyEmploymentType.partTime,

      workFormat: VacancyWorkFormat.onsite,

      location: 'Университет',

      salaryText: 'по договорённости',

      tags: ['Python', 'Алгоритмы', 'Коммуникация'],

      accentColor: Color(0xFF2F80ED),

    ),

    VacancyCardPayload(

      title: 'Дизайнер презентаций и лендингов',

      companyName: 'Студенческий проект',

      summary:

          'Нужно красиво упаковывать идеи: презентации, простые макеты и визуалы для демо.',

      descriptionFull:

          'Нужно красиво упаковывать идеи: презентации, простые макеты и визуалы для демо.',

      employmentType: VacancyEmploymentType.project,

      workFormat: VacancyWorkFormat.remote,

      location: 'Удалённо',

      salaryText: 'за задачу',

      tags: ['Figma', 'Canva', 'Визуал'],

      accentColor: Color(0xFFE16B8C),

    ),

  ];



  /// Fail-closed parser for flat RPC rows (`get_my_vacancies`).

  static VacancyCardPayload? tryParse(Map<String, dynamic>? json) {

    if (json == null) return null;

    try {

      final title = _readString(json, const ['title']);

      if (title == null) return null;

      final companyName =

          _readString(json, const ['company_name', 'companyName']) ?? '';



      final rawDescription = json['description']?.toString() ?? '';

      final split = splitVacancyDescription(rawDescription);

      final summary =

          _readString(json, const ['summary']) ??

          (split.body.isNotEmpty ? split.body : null) ??

          rawDescription.trim();

      if (summary.isEmpty) return null;



      final descriptionFull =

          split.body.isNotEmpty ? split.body : (rawDescription.trim().isEmpty ? null : rawDescription.trim());

      final requirements = split.requirements.isNotEmpty ? split.requirements : null;



      return VacancyCardPayload(

        title: title,

        companyName: companyName,

        summary: summary,

        descriptionFull: descriptionFull,

        requirementsText: requirements,

        employmentType: VacancyEmploymentType.tryParse(json['employment_type']),

        workFormat: VacancyWorkFormat.tryParse(json['work_format']),

        location: _readString(json, const ['location']),

        salaryText: _readString(json, const ['salary_text', 'salaryText']),

        externalUrl: _readString(json, const ['external_url', 'externalUrl']),

      );

    } catch (_) {

      return null;

    }

  }



  String? get employmentLabel => employmentType?.labelRu;



  String? get workFormatLabel => workFormat?.labelRu;



  String get formatLine {

    final parts = <String>[

      if (employmentLabel != null) employmentLabel!,

      if (workFormatLabel != null) workFormatLabel!,

      if (location != null && location!.isNotEmpty) location!,

    ];

    return parts.join(' · ');

  }



  bool get hasExternalUrl {

    final url = externalUrl;

    if (url == null || url.isEmpty) return false;

    return url.startsWith('https://');

  }

}



/// Masked contacts until revealed via `get_vacancy_contacts`.

@immutable

class VacancyContacts {

  const VacancyContacts({

    this.person,

    this.email,

    this.phone,

    this.telegram,

    this.url,

    this.note,

  });



  final String? person;

  final String? email;

  final String? phone;

  final String? telegram;

  final String? url;

  final String? note;



  bool get isEmpty =>

      (person ?? '').isEmpty &&

      (email ?? '').isEmpty &&

      (phone ?? '').isEmpty &&

      (telegram ?? '').isEmpty &&

      (url ?? '').isEmpty &&

      (note ?? '').isEmpty;



  factory VacancyContacts.fromJson(Map<String, dynamic>? json) {

    if (json == null || json.isEmpty) return const VacancyContacts();

    String? s(String key) {

      final v = json[key]?.toString().trim();

      return (v == null || v.isEmpty) ? null : v;

    }



    return VacancyContacts(

      person: s('person'),

      email: s('email'),

      phone: s('phone'),

      telegram: s('telegram'),

      url: s('url'),

      note: s('note'),

    );

  }

}



/// Managed vacancy card for Mobile list (`get_my_vacancies`).

@immutable

class ManagedVacancyCard {

  const ManagedVacancyCard({

    required this.id,

    required this.origin,

    required this.payload,

    this.showDemoBadge = false,

    this.hasContacts = false,

    this.assets = const [],

    this.expiresAt,

    this.publishedAt,

  });



  final String id;

  final ContentOrigin origin;

  final VacancyCardPayload payload;

  final bool showDemoBadge;

  final bool hasContacts;

  final List<VacancyAssetDescriptor> assets;

  final DateTime? expiresAt;

  final DateTime? publishedAt;



  bool get hasAssets => assets.isNotEmpty;



  bool matchesQuery(String query) {

    if (query.isEmpty) return true;

    final q = query.toLowerCase();

    final p = payload;

    return p.title.toLowerCase().contains(q) ||

        p.companyName.toLowerCase().contains(q) ||

        p.summary.toLowerCase().contains(q) ||

        (p.descriptionFull?.toLowerCase().contains(q) ?? false) ||

        (p.requirementsText?.toLowerCase().contains(q) ?? false) ||

        (p.employmentLabel?.toLowerCase().contains(q) ?? false) ||

        (p.workFormatLabel?.toLowerCase().contains(q) ?? false) ||

        (p.location?.toLowerCase().contains(q) ?? false) ||

        (p.salaryText?.toLowerCase().contains(q) ?? false) ||

        p.tags.any((tag) => tag.toLowerCase().contains(q));

  }



  /// Fail-closed parser for `get_my_vacancies` JSON rows.

  static ManagedVacancyCard? tryParse(Map<String, dynamic> json) {

    try {

      final id = _readString(json, const ['id']);

      if (id == null) return null;



      final origin = ContentOrigin.tryParse(json['origin']);

      if (origin == null) return null;



      final payload = VacancyCardPayload.tryParse(json);

      if (payload == null) return null;



      final isDemo = _readBool(json, 'is_demo') ?? origin == ContentOrigin.demo;



      return ManagedVacancyCard(

        id: id,

        origin: origin,

        payload: payload,

        showDemoBadge: isDemo,

        hasContacts: _readBool(json, 'has_contacts') ?? false,

        assets: _readVacancyAssets(json['assets'] ?? json['asset_ids']),

        expiresAt: _readDate(json['expires_at']),

        publishedAt: _readDate(json['published_at']),

      );

    } catch (_) {

      return null;

    }

  }

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


