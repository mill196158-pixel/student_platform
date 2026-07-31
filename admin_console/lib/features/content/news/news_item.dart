import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:student_ui/student_ui.dart';

import 'admin_image_store.dart';

enum NewsStatus { draft, published, archived }

enum NewsAudienceType { all, group }

/// Normalized Stage 15.2 audience mode (derived; not the legacy enum).
enum NewsAudienceMode { all, groups, users, groupsAndUsers }

NewsAudienceMode newsAudienceModeFromString(String? raw) {
  switch (raw) {
    case 'groups':
      return NewsAudienceMode.groups;
    case 'users':
      return NewsAudienceMode.users;
    case 'groups_and_users':
      return NewsAudienceMode.groupsAndUsers;
    case 'all':
    default:
      return NewsAudienceMode.all;
  }
}

String newsAudienceModeWire(NewsAudienceMode mode) {
  switch (mode) {
    case NewsAudienceMode.all:
      return 'all';
    case NewsAudienceMode.groups:
      return 'groups';
    case NewsAudienceMode.users:
      return 'users';
    case NewsAudienceMode.groupsAndUsers:
      return 'groups_and_users';
  }
}

/// How [NewsItem.toPatchJson] should treat `image_path`.
enum NewsImagePathPatch {
  /// Leave the server value unchanged (omit the key).
  omit,

  /// Persist [NewsItem.imagePath] (must be a non-empty storage path).
  set,

  /// Explicitly clear the server image_path.
  clear,
}

/// A single admin news post.
///
/// Bytes for image previews are never persisted here — only a local
/// [imageId] into [AdminImageStore] (instant preview) and/or a remote
/// [imagePath] (Supabase Storage object path) are kept.
class NewsItem {
  const NewsItem({
    required this.id,
    required this.title,
    required this.subtitle,
    this.body = '',
    required this.variant,
    required this.colors,
    this.status = NewsStatus.draft,
    this.sortOrder = 0,
    this.priority = 0,
    this.startsAt,
    this.endsAt,
    this.audienceType = NewsAudienceType.all,
    this.audienceGroupId,
    this.audienceMode = NewsAudienceMode.all,
    this.audienceGroupIds = const [],
    this.audienceUserIds = const [],
    this.isHidden = false,
    this.imageId,
    this.imagePath,
    this.imageFocus = Alignment.center,
    this.overlayDarken = 0.42,
    this.versionNumber = 1,
    this.publishedAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String subtitle;
  final String body;
  final StudentHomeNewsVariant variant;
  final List<Color> colors;
  final NewsStatus status;
  final int sortOrder;
  final int priority;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final NewsAudienceType audienceType;
  final String? audienceGroupId;
  final NewsAudienceMode audienceMode;
  final List<String> audienceGroupIds;
  final List<String> audienceUserIds;
  final bool isHidden;

  bool get usesNormalizedAudience =>
      audienceGroupIds.isNotEmpty || audienceUserIds.isNotEmpty;

  /// Reference into [AdminImageStore]. Bytes are never persisted to disk/Git.
  final String? imageId;

  /// Remote Supabase Storage object path (private bucket). Never a public URL.
  final String? imagePath;
  final Alignment imageFocus;
  final double overlayDarken;
  final int versionNumber;
  final DateTime? publishedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get usesImage =>
      variant == StudentHomeNewsVariant.imageOnly ||
      variant == StudentHomeNewsVariant.imageOverlay ||
      variant == StudentHomeNewsVariant.imageWithText;

  bool get isDraft => status == NewsStatus.draft;
  bool get isPublished => status == NewsStatus.published;
  bool get isArchived => status == NewsStatus.archived;

  NewsItem copyWith({
    String? id,
    String? title,
    String? subtitle,
    String? body,
    StudentHomeNewsVariant? variant,
    List<Color>? colors,
    NewsStatus? status,
    int? sortOrder,
    int? priority,
    DateTime? startsAt,
    bool clearStartsAt = false,
    DateTime? endsAt,
    bool clearEndsAt = false,
    NewsAudienceType? audienceType,
    String? audienceGroupId,
    bool clearAudienceGroupId = false,
    NewsAudienceMode? audienceMode,
    List<String>? audienceGroupIds,
    List<String>? audienceUserIds,
    bool? isHidden,
    String? imageId,
    bool clearImageId = false,
    String? imagePath,
    bool clearImagePath = false,
    Alignment? imageFocus,
    double? overlayDarken,
    int? versionNumber,
    DateTime? publishedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return NewsItem(
      id: id ?? this.id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      body: body ?? this.body,
      variant: variant ?? this.variant,
      colors: colors ?? this.colors,
      status: status ?? this.status,
      sortOrder: sortOrder ?? this.sortOrder,
      priority: priority ?? this.priority,
      startsAt: clearStartsAt ? null : (startsAt ?? this.startsAt),
      endsAt: clearEndsAt ? null : (endsAt ?? this.endsAt),
      audienceType: audienceType ?? this.audienceType,
      audienceGroupId: clearAudienceGroupId
          ? null
          : (audienceGroupId ?? this.audienceGroupId),
      audienceMode: audienceMode ?? this.audienceMode,
      audienceGroupIds: audienceGroupIds ?? this.audienceGroupIds,
      audienceUserIds: audienceUserIds ?? this.audienceUserIds,
      isHidden: isHidden ?? this.isHidden,
      imageId: clearImageId ? null : (imageId ?? this.imageId),
      imagePath: clearImagePath ? null : (imagePath ?? this.imagePath),
      imageFocus: imageFocus ?? this.imageFocus,
      overlayDarken: overlayDarken ?? this.overlayDarken,
      versionNumber: versionNumber ?? this.versionNumber,
      publishedAt: publishedAt ?? this.publishedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const _fallbackColors = [Color(0xFF7367F0), Color(0xFFB784F7)];

  static final _defaultIcons = <IconData>[
    Icons.auto_awesome_rounded,
    Icons.edit_note_rounded,
    Icons.campaign_outlined,
    Icons.assignment_turned_in_outlined,
  ];

  IconData get _icon {
    // Image variants must not rely on a decorative folder/glyph overlay.
    if (usesImage) return Icons.auto_awesome_rounded;
    final seed = id.hashCode.abs();
    return _defaultIcons[seed % _defaultIcons.length];
  }

  /// Presentation model for the shared student widgets.
  ///
  /// [bytes] (caller-provided, e.g. resolved from a remote path) takes
  /// precedence; otherwise local preview bytes from [imageStore] are used.
  StudentHomeNews toPresentation({
    AdminImageStore? imageStore,
    Uint8List? bytes,
  }) {
    Uint8List? resolved = bytes;
    if (resolved == null && imageId != null && imageStore != null) {
      resolved = imageStore.getBytes(imageId!);
    }
    return StudentHomeNews(
      id: 'admin-news-$id',
      title: title,
      subtitle: subtitle,
      body: body.isNotEmpty ? body : subtitle,
      icon: _icon,
      gradientColors: colors,
      variant: variant,
      imageBytes: resolved,
      imageFocus: imageFocus,
      overlayDarken: overlayDarken,
      publishedAt: publishedAt ?? createdAt,
    );
  }

  /// Parses a `news_post_to_json` payload returned by the admin RPCs.
  factory NewsItem.fromJson(Map<String, dynamic> json) {
    return NewsItem(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      subtitle: (json['subtitle'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      variant: newsVariantFromString(json['variant']?.toString()),
      colors: _colorsFromHex(json['gradient_colors']),
      status: _statusFromString(json['status']?.toString()),
      sortOrder: _asInt(json['sort_order']),
      priority: _asInt(json['priority']),
      startsAt: _asDate(json['starts_at']),
      endsAt: _asDate(json['ends_at']),
      audienceType: _audienceFromString(json['audience_type']?.toString()),
      audienceGroupId: _asNullableString(json['audience_group_id']),
      audienceMode: _inferAudienceMode(json),
      audienceGroupIds: _inferAudienceGroupIds(json),
      audienceUserIds: _asIdList(json['audience_user_ids']),
      isHidden: json['is_hidden'] == true,
      imagePath: _asNullableString(json['image_path']),
      imageFocus: Alignment(
        _asDouble(json['image_focus_x']),
        _asDouble(json['image_focus_y']),
      ),
      overlayDarken: _asDouble(json['overlay_opacity'], fallback: 0.42),
      versionNumber: _asInt(json['version_number'], fallback: 1),
      publishedAt: _asDate(json['published_at']),
      createdAt: _asDate(json['created_at']),
      updatedAt: _asDate(json['updated_at']),
    );
  }

  /// Patch payload consumed by `admin_update_news_draft(p_id, p_patch)`.
  ///
  /// By default [imagePathPatch] is [NewsImagePathPatch.omit] so text/variant
  /// edits never wipe an existing server `image_path`.
  Map<String, dynamic> toPatchJson({
    NewsImagePathPatch imagePathPatch = NewsImagePathPatch.omit,
  }) {
    final map = <String, dynamic>{
      'title': title,
      'subtitle': subtitle,
      'body': body,
      'variant': variant.label,
      'gradient_colors': colors.map(colorToHex).toList(),
      'image_focus_x': imageFocus.x,
      'image_focus_y': imageFocus.y,
      'overlay_opacity': overlayDarken,
      'is_hidden': isHidden,
      'priority': priority,
      'starts_at': startsAt?.toUtc().toIso8601String() ?? '',
      'ends_at': endsAt?.toUtc().toIso8601String() ?? '',
      // Audience is owned by admin_set_news_audience — never patch here.
      'sort_order': sortOrder,
    };
    switch (imagePathPatch) {
      case NewsImagePathPatch.omit:
        break;
      case NewsImagePathPatch.set:
        map['image_path'] = imagePath ?? '';
        break;
      case NewsImagePathPatch.clear:
        map['image_path'] = '';
        break;
    }
    return map;
  }
}

class NewsVersionInfo {
  const NewsVersionInfo({
    required this.versionNumber,
    this.createdAt,
    this.createdBy,
    this.title = '',
    this.status,
  });

  final int versionNumber;
  final DateTime? createdAt;
  final String? createdBy;
  final String title;
  final NewsStatus? status;

  factory NewsVersionInfo.fromJson(Map<String, dynamic> json) {
    final snapshot = json['snapshot'];
    String title = '';
    NewsStatus? status;
    if (snapshot is Map) {
      title = (snapshot['title'] ?? '').toString();
      status = _statusFromString(snapshot['status']?.toString());
    }
    return NewsVersionInfo(
      versionNumber: _asInt(json['version_number']),
      createdAt: _asDate(json['created_at']),
      createdBy: _asNullableString(json['created_by']),
      title: title,
      status: status,
    );
  }
}

extension StudentHomeNewsVariantLabel on StudentHomeNewsVariant {
  String get label => switch (this) {
    StudentHomeNewsVariant.gradientText => 'gradientText',
    StudentHomeNewsVariant.imageOverlay => 'imageOverlay',
    StudentHomeNewsVariant.imageOnly => 'imageOnly',
    StudentHomeNewsVariant.imageWithText => 'imageWithText',
  };

  String get russianLabel => switch (this) {
    StudentHomeNewsVariant.gradientText => 'Градиент и текст',
    StudentHomeNewsVariant.imageOverlay => 'Картинка с текстом поверх',
    StudentHomeNewsVariant.imageOnly => 'Только картинка',
    StudentHomeNewsVariant.imageWithText => 'Картинка и текстовый блок',
  };
}

extension NewsStatusLabel on NewsStatus {
  String get russianLabel => switch (this) {
    NewsStatus.draft => 'Черновик',
    NewsStatus.published => 'Опубликован',
    NewsStatus.archived => 'В архиве',
  };
}

StudentHomeNewsVariant newsVariantFromString(String? value) {
  switch (value) {
    case 'imageOverlay':
      return StudentHomeNewsVariant.imageOverlay;
    case 'imageOnly':
      return StudentHomeNewsVariant.imageOnly;
    case 'imageWithText':
      return StudentHomeNewsVariant.imageWithText;
    case 'gradientText':
    default:
      return StudentHomeNewsVariant.gradientText;
  }
}

String colorToHex(Color color) {
  final argb = color.toARGB32();
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  String two(int v) => v.toRadixString(16).padLeft(2, '0');
  return '#${two(r)}${two(g)}${two(b)}'.toUpperCase();
}

Color colorFromHex(String value) {
  var hex = value.replaceAll('#', '').trim();
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length == 6) {
    hex = 'FF$hex';
  }
  final parsed = int.tryParse(hex, radix: 16);
  if (parsed == null) return NewsItem._fallbackColors.first;
  return Color(parsed);
}

List<Color> _colorsFromHex(dynamic raw) {
  if (raw is List) {
    final colors = <Color>[];
    for (final item in raw) {
      if (item != null) colors.add(colorFromHex(item.toString()));
    }
    if (colors.length >= 2) return colors;
    if (colors.length == 1) return [colors.first, colors.first];
  }
  return NewsItem._fallbackColors;
}

NewsStatus _statusFromString(String? value) {
  switch (value) {
    case 'published':
      return NewsStatus.published;
    case 'archived':
      return NewsStatus.archived;
    case 'draft':
    default:
      return NewsStatus.draft;
  }
}

NewsAudienceType _audienceFromString(String? value) {
  return value == 'group' ? NewsAudienceType.group : NewsAudienceType.all;
}

int _asInt(dynamic value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

double _asDouble(dynamic value, {double fallback = 0}) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}

DateTime? _asDate(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

List<String> _asIdList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => e?.toString().trim() ?? '')
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}

NewsAudienceMode _inferAudienceMode(Map<String, dynamic> json) {
  final rawMode = json['audience_mode']?.toString();
  if (rawMode != null && rawMode.trim().isNotEmpty) {
    return newsAudienceModeFromString(rawMode);
  }
  final groups = _asIdList(json['audience_group_ids']);
  final users = _asIdList(json['audience_user_ids']);
  if (groups.isNotEmpty && users.isNotEmpty) {
    return NewsAudienceMode.groupsAndUsers;
  }
  if (users.isNotEmpty) return NewsAudienceMode.users;
  if (groups.isNotEmpty) return NewsAudienceMode.groups;
  final legacyType = _audienceFromString(json['audience_type']?.toString());
  final legacyGroup = _asNullableString(json['audience_group_id']);
  if (legacyType == NewsAudienceType.group && legacyGroup != null) {
    return NewsAudienceMode.groups;
  }
  return NewsAudienceMode.all;
}

List<String> _inferAudienceGroupIds(Map<String, dynamic> json) {
  final groups = _asIdList(json['audience_group_ids']);
  if (groups.isNotEmpty) return groups;
  final legacyGroup = _asNullableString(json['audience_group_id']);
  if (legacyGroup == null) return const [];
  return [legacyGroup];
}

String? _asNullableString(dynamic value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}
