import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Approved content placements (server enum). Never show raw values in UI.
enum ContentPlacement {
  homePromo,
  profileFeed,
  reference;

  static ContentPlacement? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'home_promo':
        return ContentPlacement.homePromo;
      case 'profile_feed':
        return ContentPlacement.profileFeed;
      case 'reference':
        return ContentPlacement.reference;
      default:
        return null;
    }
  }
}

enum ContentOrigin {
  demo,
  admin,
  importSource,
  userSubmission;

  /// Fail-closed: unknown origin returns null.
  static ContentOrigin? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw) {
      case 'demo':
        return ContentOrigin.demo;
      case 'admin':
        return ContentOrigin.admin;
      case 'import':
        return ContentOrigin.importSource;
      case 'user_submission':
        return ContentOrigin.userSubmission;
      default:
        return null;
    }
  }

  /// Russian label for Admin filters / demo badges.
  String get labelRu {
    switch (this) {
      case ContentOrigin.demo:
        return 'Пример';
      case ContentOrigin.admin:
        return 'Админ';
      case ContentOrigin.importSource:
        return 'Импорт';
      case ContentOrigin.userSubmission:
        return 'Заявка';
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

bool? _readBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is bool) return value;
  return null;
}

double? _readDouble(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value == null) continue;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
  return null;
}

/// Typed home promo payload for template `home_promo_v1`.
@immutable
class HomePromoPayload {
  const HomePromoPayload({
    required this.title,
    required this.subtitle,
    required this.iconKey,
    required this.gradientColors,
    required this.ctaLabel,
    required this.dismissible,
    this.imageAssetId,
    this.ctaRoute,
    this.ctaUrl,
    this.reshowAfterHours,
    this.homeSlot,
    this.cardVariant,
    this.iconAssetId,
    this.gradientAngle,
    this.action,
    this.overlayOpacity,
    this.focalX,
    this.focalY,
    this.imageFit,
  });

  final String title;
  final String subtitle;
  final String iconKey;
  final List<Color> gradientColors;
  final String ctaLabel;
  final bool dismissible;
  final String? imageAssetId;
  final String? ctaRoute;
  final String? ctaUrl;
  final int? reshowAfterHours;

  /// Stage 14.1.2 dual-read (schema v2). Defaults to after_assignments when null.
  final String? homeSlot;

  /// Stage 14.1.2 dual-read card presentation variant.
  final String? cardVariant;

  /// Optional custom icon asset (schema v2).
  final String? iconAssetId;

  /// Gradient direction in degrees (schema v2).
  final int? gradientAngle;

  /// Structured tap action (schema v2).
  final Map<String, dynamic>? action;

  /// Image overlay dim (0..1) for image_overlay variant.
  final double? overlayOpacity;

  /// Focal point for hero image (0..1).
  final double? focalX;
  final double? focalY;

  /// Hero image fit: cover | contain (default cover when null).
  final String? imageFit;

  /// Built-in demo matching the historic hardcoded Home help card.
  static const HomePromoPayload demoStuckWithAssignment = HomePromoPayload(
    title: 'Застрял с заданием?',
    subtitle:
        'Можно разобрать задачу, подготовиться к сдаче или понять, с чего начать.',
    iconKey: 'psychology',
    gradientColors: [Color(0xFFFFFBFF), Color(0xFFF3EEF9)],
    ctaLabel: 'Получить помощь',
    dismissible: false,
    ctaRoute: '/help',
  );

  /// Fail-closed parser: returns null on missing/malformed fields (never throws).
  static HomePromoPayload? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final title = _readString(json, const ['title']);
      final subtitle = _readString(json, const ['subtitle']);
      final iconKey = _readString(json, const ['iconKey', 'icon_key']);
      final ctaLabel = _readString(json, const ['ctaLabel', 'cta_label']);
      if (title == null ||
          subtitle == null ||
          iconKey == null ||
          ctaLabel == null) {
        return null;
      }

      final dismissible = _readBool(json, 'dismissible');
      if (dismissible == null) return null;

      final gradientRaw = json['gradientColors'] ?? json['gradient_colors'];
      if (gradientRaw is! List) return null;
      final colors = <Color>[];
      for (final item in gradientRaw) {
        final parsed = _parseColor(item);
        if (parsed == null) return null;
        colors.add(parsed);
      }
      if (colors.length < 2 || colors.length > 4) return null;

      final imageAssetId =
          _readString(json, const ['imageAssetId', 'image_asset_id']);
      final ctaRoute = _readString(json, const ['ctaRoute', 'cta_route']);
      final ctaUrl = _readString(json, const ['ctaUrl', 'cta_url']);
      final reshow = _readInt(json, const [
        'reshowAfterHours',
        'reshow_after_hours',
      ]);
      if (json.containsKey('reshow_after_hours') ||
          json.containsKey('reshowAfterHours')) {
        if (reshow == null || reshow < 1 || reshow > 8760) return null;
      }

      double? overlayOpacity;
      if (json.containsKey('overlay_opacity') ||
          json.containsKey('overlayOpacity')) {
        final raw = _readDouble(json, const [
          'overlayOpacity',
          'overlay_opacity',
        ]);
        if (raw == null || raw < 0 || raw > 1) return null;
        overlayOpacity = raw;
      }

      double? focalX;
      if (json.containsKey('focal_x') || json.containsKey('focalX')) {
        final raw = _readDouble(json, const ['focalX', 'focal_x']);
        if (raw == null || raw < 0 || raw > 1) return null;
        focalX = raw;
      }

      double? focalY;
      if (json.containsKey('focal_y') || json.containsKey('focalY')) {
        final raw = _readDouble(json, const ['focalY', 'focal_y']);
        if (raw == null || raw < 0 || raw > 1) return null;
        focalY = raw;
      }

      String? imageFit;
      if (json.containsKey('image_fit') || json.containsKey('imageFit')) {
        final raw = _readString(json, const ['imageFit', 'image_fit']);
        if (raw != 'cover' && raw != 'contain') return null;
        imageFit = raw;
      }

      return HomePromoPayload(
        title: title,
        subtitle: subtitle,
        iconKey: iconKey,
        gradientColors: colors,
        ctaLabel: ctaLabel,
        dismissible: dismissible,
        imageAssetId: imageAssetId,
        ctaRoute: ctaRoute,
        ctaUrl: ctaUrl,
        reshowAfterHours: reshow,
        homeSlot: _readString(json, const ['homeSlot', 'home_slot']),
        cardVariant: _readString(json, const ['cardVariant', 'card_variant']),
        iconAssetId: _readString(json, const ['iconAssetId', 'icon_asset_id']),
        gradientAngle: _readInt(json, const [
          'gradientAngle',
          'gradient_angle',
        ]),
        action: json['action'] is Map
            ? Map<String, dynamic>.from(json['action'] as Map)
            : null,
        overlayOpacity: overlayOpacity,
        focalX: focalX,
        focalY: focalY,
        imageFit: imageFit,
      );
    } catch (_) {
      return null;
    }
  }

  IconData get iconData => contentIconForKey(iconKey);

  /// Effective home slot for layout (legacy default).
  String get effectiveHomeSlot => homeSlot ?? 'after_assignments';

  /// Wire format for `home_promo_v1` RPCs (snake_case).
  Map<String, dynamic> toWireJson() {
    return {
      'title': title,
      'subtitle': subtitle,
      'icon_key': iconKey,
      'gradient_colors': [
        for (final color in gradientColors) _colorToHex(color),
      ],
      'cta_label': ctaLabel,
      'dismissible': dismissible,
      if (imageAssetId != null) 'image_asset_id': imageAssetId,
      if (ctaRoute != null) 'cta_route': ctaRoute,
      if (ctaUrl != null) 'cta_url': ctaUrl,
      if (reshowAfterHours != null) 'reshow_after_hours': reshowAfterHours,
      if (homeSlot != null) 'home_slot': homeSlot,
      if (cardVariant != null) 'card_variant': cardVariant,
      if (iconAssetId != null) 'icon_asset_id': iconAssetId,
      if (gradientAngle != null) 'gradient_angle': gradientAngle,
      if (action != null) 'action': action,
      if (overlayOpacity != null) 'overlay_opacity': overlayOpacity,
      if (focalX != null) 'focal_x': focalX,
      if (focalY != null) 'focal_y': focalY,
      if (imageFit != null) 'image_fit': imageFit,
    };
  }

  HomePromoPayload copyWith({
    String? title,
    String? subtitle,
    String? iconKey,
    List<Color>? gradientColors,
    String? ctaLabel,
    bool? dismissible,
    String? imageAssetId,
    String? ctaRoute,
    String? ctaUrl,
    int? reshowAfterHours,
    String? homeSlot,
    String? cardVariant,
    String? iconAssetId,
    int? gradientAngle,
    Map<String, dynamic>? action,
    double? overlayOpacity,
    double? focalX,
    double? focalY,
    String? imageFit,
    bool clearImageAssetId = false,
    bool clearCtaRoute = false,
    bool clearCtaUrl = false,
    bool clearReshowAfterHours = false,
    bool clearHomeSlot = false,
    bool clearCardVariant = false,
    bool clearIconAssetId = false,
    bool clearGradientAngle = false,
    bool clearAction = false,
    bool clearOverlayOpacity = false,
    bool clearFocalX = false,
    bool clearFocalY = false,
    bool clearImageFit = false,
  }) {
    return HomePromoPayload(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      iconKey: iconKey ?? this.iconKey,
      gradientColors: gradientColors ?? this.gradientColors,
      ctaLabel: ctaLabel ?? this.ctaLabel,
      dismissible: dismissible ?? this.dismissible,
      imageAssetId:
          clearImageAssetId ? null : (imageAssetId ?? this.imageAssetId),
      ctaRoute: clearCtaRoute ? null : (ctaRoute ?? this.ctaRoute),
      ctaUrl: clearCtaUrl ? null : (ctaUrl ?? this.ctaUrl),
      reshowAfterHours: clearReshowAfterHours
          ? null
          : (reshowAfterHours ?? this.reshowAfterHours),
      homeSlot: clearHomeSlot ? null : (homeSlot ?? this.homeSlot),
      cardVariant: clearCardVariant ? null : (cardVariant ?? this.cardVariant),
      iconAssetId: clearIconAssetId ? null : (iconAssetId ?? this.iconAssetId),
      gradientAngle:
          clearGradientAngle ? null : (gradientAngle ?? this.gradientAngle),
      action: clearAction ? null : (action ?? this.action),
      overlayOpacity:
          clearOverlayOpacity ? null : (overlayOpacity ?? this.overlayOpacity),
      focalX: clearFocalX ? null : (focalX ?? this.focalX),
      focalY: clearFocalY ? null : (focalY ?? this.focalY),
      imageFit: clearImageFit ? null : (imageFit ?? this.imageFit),
    );
  }

  static Color? _parseColor(Object? raw) {
    if (raw is! String) return null;
    var hex = raw.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return Color(value);
  }

  static String _colorToHex(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

@immutable
class ManagedContentCard {
  const ManagedContentCard({
    required this.id,
    required this.templateKey,
    required this.schemaVersion,
    required this.origin,
    required this.placement,
    required this.sortOrder,
    required this.priority,
    required this.homePromo,
    this.showDemoBadge = false,
  });

  final String id;
  final String templateKey;
  final int schemaVersion;
  final ContentOrigin origin;
  final ContentPlacement placement;
  final int sortOrder;
  final int priority;
  final HomePromoPayload homePromo;
  final bool showDemoBadge;

  /// Fail-closed parser for `home_promo_v1` / schema_version 1.
  static ManagedContentCard? tryParseHomePromo(Map<String, dynamic> json) {
    try {
      final id = _readString(json, const ['id']);
      if (id == null) return null;

      final templateKeyRaw = _readString(json, const [
        'template_key',
        'templateKey',
      ]);
      if (templateKeyRaw == null || templateKeyRaw != 'home_promo_v1') {
        return null;
      }

      final schemaVersionRaw = _readInt(json, const [
        'schema_version',
        'schemaVersion',
      ]);
      if (schemaVersionRaw == null || schemaVersionRaw != 1) {
        return null;
      }

      if (json.containsKey('placement') || json.containsKey('placements')) {
        final placementRaw = json['placement'];
        if (placementRaw != null &&
            ContentPlacement.tryParse(placementRaw) !=
                ContentPlacement.homePromo) {
          return null;
        }
      }

      final origin = ContentOrigin.tryParse(json['origin']);
      if (origin == null) return null;

      final payloadRaw = json['payload'];
      if (payloadRaw is! Map) return null;
      final payload = HomePromoPayload.tryParse(
        Map<String, dynamic>.from(payloadRaw),
      );
      if (payload == null) return null;

      final sortOrder = _readInt(json, const ['sort_order', 'sortOrder']) ?? 0;
      final priority = _readInt(json, const ['priority']) ?? 0;

      return ManagedContentCard(
        id: id,
        templateKey: templateKeyRaw,
        schemaVersion: schemaVersionRaw,
        origin: origin,
        placement: ContentPlacement.homePromo,
        sortOrder: sortOrder,
        priority: priority,
        homePromo: payload,
        showDemoBadge: origin == ContentOrigin.demo,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Typed payload for template `profile_feed_card_v1`.
@immutable
class ProfileFeedPayload {
  const ProfileFeedPayload({
    required this.title,
    required this.subtitle,
    required this.ctaLabel,
    this.imageAssetId,
    this.ctaRoute,
    this.ctaUrl,
    this.iconKey,
    this.iconAssetId,
    this.cardVariant,
    this.bgMode,
    this.bgColor,
    this.gradientColors,
    this.gradientAngle,
    this.overlayOpacity,
    this.action,
  });

  final String title;
  final String subtitle;
  final String ctaLabel;
  final String? imageAssetId;
  final String? ctaRoute;
  final String? ctaUrl;

  /// Stage 14.1.2 dual-read (schema v2).
  final String? iconKey;
  final String? iconAssetId;
  final String? cardVariant;
  final String? bgMode;
  final Color? bgColor;
  final List<Color>? gradientColors;
  final int? gradientAngle;
  final double? overlayOpacity;

  /// Structured tap action (schema v2).
  final Map<String, dynamic>? action;

  static const List<ProfileFeedPayload> demoFeed = [
    ProfileFeedPayload(
      title: 'О нас',
      subtitle: 'Команда Студент Платформ',
      ctaLabel: 'Открыть',
      ctaUrl: 'https://example.com/about',
    ),
    ProfileFeedPayload(
      title: 'Расписание занятий',
      subtitle: 'Твое расписание всегда под рукой',
      ctaLabel: 'К расписанию',
      ctaRoute: '/schedule',
    ),
    ProfileFeedPayload(
      title: 'Скидки для студентов',
      subtitle: 'Обновляем лучшие предложения',
      ctaLabel: 'Смотреть',
      ctaUrl: 'https://example.com/discounts',
    ),
  ];

  static ProfileFeedPayload? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      final title = _readString(json, const ['title']);
      final subtitle = _readString(json, const ['subtitle']);
      final ctaLabel = _readString(json, const ['ctaLabel', 'cta_label']);
      if (title == null || subtitle == null || ctaLabel == null) return null;

      List<Color>? gradientColors;
      if (json.containsKey('gradientColors') ||
          json.containsKey('gradient_colors')) {
        final gradientRaw = json['gradientColors'] ?? json['gradient_colors'];
        if (gradientRaw is! List) return null;
        final colors = <Color>[];
        for (final item in gradientRaw) {
          final parsed = _parseProfileFeedColor(item);
          if (parsed == null) return null;
          colors.add(parsed);
        }
        if (colors.length < 2 || colors.length > 4) return null;
        gradientColors = colors;
      }

      Color? bgColor;
      if (json.containsKey('bgColor') || json.containsKey('bg_color')) {
        final raw = json['bgColor'] ?? json['bg_color'];
        bgColor = _parseProfileFeedColor(raw);
        if (bgColor == null) return null;
      }

      final overlayOpacity = _readDouble(json, const [
        'overlayOpacity',
        'overlay_opacity',
      ]);
      if ((json.containsKey('overlayOpacity') ||
              json.containsKey('overlay_opacity')) &&
          overlayOpacity == null) {
        return null;
      }

      return ProfileFeedPayload(
        title: title,
        subtitle: subtitle,
        ctaLabel: ctaLabel,
        imageAssetId:
            _readString(json, const ['imageAssetId', 'image_asset_id']),
        ctaRoute: _readString(json, const ['ctaRoute', 'cta_route']),
        ctaUrl: _readString(json, const ['ctaUrl', 'cta_url']),
        iconKey: _readString(json, const ['iconKey', 'icon_key']),
        iconAssetId: _readString(json, const ['iconAssetId', 'icon_asset_id']),
        cardVariant: _readString(json, const ['cardVariant', 'card_variant']),
        bgMode: _readString(json, const ['bgMode', 'bg_mode']),
        bgColor: bgColor,
        gradientColors: gradientColors,
        gradientAngle: _readInt(json, const [
          'gradientAngle',
          'gradient_angle',
        ]),
        overlayOpacity: overlayOpacity,
        action: json['action'] is Map
            ? Map<String, dynamic>.from(json['action'] as Map)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  IconData get iconData => contentIconForKey(iconKey ?? 'info');

  Map<String, dynamic> toWireJson() => {
        'title': title,
        'subtitle': subtitle,
        'cta_label': ctaLabel,
        if (imageAssetId != null) 'image_asset_id': imageAssetId,
        if (ctaRoute != null) 'cta_route': ctaRoute,
        if (ctaUrl != null) 'cta_url': ctaUrl,
        if (iconKey != null) 'icon_key': iconKey,
        if (iconAssetId != null) 'icon_asset_id': iconAssetId,
        if (cardVariant != null) 'card_variant': cardVariant,
        if (bgMode != null) 'bg_mode': bgMode,
        if (bgColor != null) 'bg_color': _profileFeedColorToHex(bgColor!),
        if (gradientColors != null)
          'gradient_colors': [
            for (final color in gradientColors!) _profileFeedColorToHex(color),
          ],
        if (gradientAngle != null) 'gradient_angle': gradientAngle,
        if (overlayOpacity != null) 'overlay_opacity': overlayOpacity,
        if (action != null) 'action': action,
      };

  ProfileFeedPayload copyWith({
    String? title,
    String? subtitle,
    String? ctaLabel,
    String? imageAssetId,
    String? ctaRoute,
    String? ctaUrl,
    String? iconKey,
    String? iconAssetId,
    String? cardVariant,
    String? bgMode,
    Color? bgColor,
    List<Color>? gradientColors,
    int? gradientAngle,
    double? overlayOpacity,
    Map<String, dynamic>? action,
    bool clearImageAssetId = false,
    bool clearCtaRoute = false,
    bool clearCtaUrl = false,
    bool clearIconKey = false,
    bool clearIconAssetId = false,
    bool clearCardVariant = false,
    bool clearBgMode = false,
    bool clearBgColor = false,
    bool clearGradientColors = false,
    bool clearGradientAngle = false,
    bool clearOverlayOpacity = false,
    bool clearAction = false,
  }) {
    return ProfileFeedPayload(
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      ctaLabel: ctaLabel ?? this.ctaLabel,
      imageAssetId:
          clearImageAssetId ? null : (imageAssetId ?? this.imageAssetId),
      ctaRoute: clearCtaRoute ? null : (ctaRoute ?? this.ctaRoute),
      ctaUrl: clearCtaUrl ? null : (ctaUrl ?? this.ctaUrl),
      iconKey: clearIconKey ? null : (iconKey ?? this.iconKey),
      iconAssetId: clearIconAssetId ? null : (iconAssetId ?? this.iconAssetId),
      cardVariant: clearCardVariant ? null : (cardVariant ?? this.cardVariant),
      bgMode: clearBgMode ? null : (bgMode ?? this.bgMode),
      bgColor: clearBgColor ? null : (bgColor ?? this.bgColor),
      gradientColors:
          clearGradientColors ? null : (gradientColors ?? this.gradientColors),
      gradientAngle:
          clearGradientAngle ? null : (gradientAngle ?? this.gradientAngle),
      overlayOpacity:
          clearOverlayOpacity ? null : (overlayOpacity ?? this.overlayOpacity),
      action: clearAction ? null : (action ?? this.action),
    );
  }

  static Color? _parseProfileFeedColor(Object? raw) {
    if (raw is! String) return null;
    var hex = raw.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return Color(value);
  }

  static String _profileFeedColorToHex(Color color) {
    final value = color.toARGB32() & 0xFFFFFF;
    return '#${value.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

@immutable
class ManagedProfileFeedCard {
  const ManagedProfileFeedCard({
    required this.id,
    required this.origin,
    required this.sortOrder,
    required this.priority,
    required this.payload,
    this.showDemoBadge = false,
    this.imageBytes,
    this.iconBytes,
    this.imageLoading = false,
  });

  final String id;
  final ContentOrigin origin;
  final int sortOrder;
  final int priority;
  final ProfileFeedPayload payload;
  final bool showDemoBadge;
  final Uint8List? imageBytes;
  final Uint8List? iconBytes;
  final bool imageLoading;

  ManagedProfileFeedCard copyWith({
    String? id,
    ContentOrigin? origin,
    int? sortOrder,
    int? priority,
    ProfileFeedPayload? payload,
    bool? showDemoBadge,
    Uint8List? imageBytes,
    Uint8List? iconBytes,
    bool? imageLoading,
    bool clearImageBytes = false,
    bool clearIconBytes = false,
  }) {
    return ManagedProfileFeedCard(
      id: id ?? this.id,
      origin: origin ?? this.origin,
      sortOrder: sortOrder ?? this.sortOrder,
      priority: priority ?? this.priority,
      payload: payload ?? this.payload,
      showDemoBadge: showDemoBadge ?? this.showDemoBadge,
      imageBytes: clearImageBytes ? null : (imageBytes ?? this.imageBytes),
      iconBytes: clearIconBytes ? null : (iconBytes ?? this.iconBytes),
      imageLoading: imageLoading ?? this.imageLoading,
    );
  }

  static ManagedProfileFeedCard? tryParse(Map<String, dynamic> json) {
    try {
      final id = _readString(json, const ['id']);
      if (id == null) return null;
      final templateKey = _readString(json, const [
        'template_key',
        'templateKey',
      ]);
      if (templateKey != 'profile_feed_card_v1') return null;
      final schemaVersion = _readInt(json, const [
        'schema_version',
        'schemaVersion',
      ]);
      if (schemaVersion == null || (schemaVersion != 1 && schemaVersion != 2)) {
        return null;
      }
      if (json.containsKey('placement') || json.containsKey('placements')) {
        final placementRaw = json['placement'];
        if (placementRaw != null &&
            ContentPlacement.tryParse(placementRaw) !=
                ContentPlacement.profileFeed) {
          return null;
        }
      }
      final origin = ContentOrigin.tryParse(json['origin']);
      if (origin == null) return null;
      final payloadRaw = json['payload'];
      if (payloadRaw is! Map) return null;
      final payload = ProfileFeedPayload.tryParse(
        Map<String, dynamic>.from(payloadRaw),
      );
      if (payload == null) return null;
      return ManagedProfileFeedCard(
        id: id,
        origin: origin,
        sortOrder: _readInt(json, const ['sort_order', 'sortOrder']) ?? 0,
        priority: _readInt(json, const ['priority']) ?? 0,
        payload: payload,
        showDemoBadge: origin == ContentOrigin.demo,
      );
    } catch (_) {
      return null;
    }
  }
}

IconData contentIconForKey(String key) {
  switch (key) {
    case 'psychology':
    case 'psychology_alt_outlined':
      return Icons.psychology_alt_outlined;
    case 'info':
      return Icons.info_outline_rounded;
    case 'school':
      return Icons.school_outlined;
    case 'help':
      return Icons.help_outline_rounded;
    case 'work':
      return Icons.work_outline_rounded;
    case 'login':
      return Icons.login_rounded;
    case 'download':
      return Icons.download_rounded;
    case 'description':
      return Icons.description_outlined;
    case 'computer':
      return Icons.computer_rounded;
    case 'map':
      return Icons.map_outlined;
    default:
      return Icons.auto_awesome_outlined;
  }
}
