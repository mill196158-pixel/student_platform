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
      );
    } catch (_) {
      return null;
    }
  }

  IconData get iconData => contentIconForKey(iconKey);

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
    default:
      return Icons.auto_awesome_outlined;
  }
}
