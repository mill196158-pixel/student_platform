import 'package:flutter/material.dart';

/// Approved content placements (server enum). Never show raw values in UI.
enum ContentPlacement {
  homePromo,
  profileFeed,
  reference;

  static ContentPlacement? tryParse(String? raw) {
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

  static ContentOrigin tryParse(String? raw) {
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
        return ContentOrigin.admin;
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

  static HomePromoPayload? tryParse(Map<String, dynamic>? json) {
    if (json == null) return null;
    final title = (json['title'] as String?)?.trim() ?? '';
    final subtitle = (json['subtitle'] as String?)?.trim() ?? '';
    final iconKey =
        (json['iconKey'] as String?)?.trim() ??
        (json['icon_key'] as String?)?.trim() ??
        '';
    final ctaLabel =
        (json['ctaLabel'] as String?)?.trim() ??
        (json['cta_label'] as String?)?.trim() ??
        '';
    if (title.isEmpty ||
        subtitle.isEmpty ||
        iconKey.isEmpty ||
        ctaLabel.isEmpty) {
      return null;
    }

    final gradientRaw = json['gradientColors'] ?? json['gradient_colors'];
    final colors = <Color>[];
    if (gradientRaw is List) {
      for (final item in gradientRaw) {
        final parsed = _parseColor(item);
        if (parsed != null) colors.add(parsed);
      }
    }
    if (colors.length < 2) {
      colors
        ..clear()
        ..addAll(const [Color(0xFFFFFBFF), Color(0xFFF3EEF9)]);
    }

    final dismissible = json['dismissible'] == true;
    final reshow = json['reshowAfterHours'] ?? json['reshow_after_hours'];

    return HomePromoPayload(
      title: title,
      subtitle: subtitle,
      iconKey: iconKey,
      gradientColors: colors,
      ctaLabel: ctaLabel,
      dismissible: dismissible,
      imageAssetId:
          (json['imageAssetId'] as String?) ??
          (json['image_asset_id'] as String?),
      ctaRoute: (json['ctaRoute'] as String?) ?? (json['cta_route'] as String?),
      ctaUrl: (json['ctaUrl'] as String?) ?? (json['cta_url'] as String?),
      reshowAfterHours: reshow is int ? reshow : int.tryParse('$reshow'),
    );
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

  static ManagedContentCard? tryParseHomePromo(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final templateKey =
        (json['template_key'] as String?) ??
        (json['templateKey'] as String?) ??
        '';
    if (templateKey != 'home_promo_v1') return null;
    final payloadRaw = json['payload'];
    final payloadMap = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : <String, dynamic>{};
    final payload = HomePromoPayload.tryParse(payloadMap);
    if (payload == null) return null;
    final origin = ContentOrigin.tryParse(
      (json['origin'] as String?) ?? 'admin',
    );
    return ManagedContentCard(
      id: id,
      templateKey: templateKey,
      schemaVersion:
          (json['schema_version'] as int?) ??
          (json['schemaVersion'] as int?) ??
          1,
      origin: origin,
      placement: ContentPlacement.homePromo,
      sortOrder:
          (json['sort_order'] as int?) ?? (json['sortOrder'] as int?) ?? 0,
      priority: (json['priority'] as int?) ?? 0,
      homePromo: payload,
      showDemoBadge: origin == ContentOrigin.demo,
    );
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
