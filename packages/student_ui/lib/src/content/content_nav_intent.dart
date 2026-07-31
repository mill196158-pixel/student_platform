/// Pure navigation intents for managed content CTAs.
///
/// Parsing/validation lives here. App routing / tab switching / sheets are
/// executed by the host app (Mobile), never by this package.
library;

/// Main app tabs that content may request (matches [MainTab] names).
enum ContentAppTab {
  home,
  info,
  learning,
  schedule,
  profile,
}

/// Fail-closed result of resolving a content tap action.
sealed class ContentNavIntent {
  const ContentNavIntent();
}

/// Switch to a main bottom-nav tab.
final class ContentNavAppTab extends ContentNavIntent {
  const ContentNavAppTab(this.tab);
  final ContentAppTab tab;
}

/// Open personal diary (`/my-diary` on Mobile).
final class ContentNavDiary extends ContentNavIntent {
  const ContentNavDiary();
}

/// Open a published reference article by id (if authorized & loaded).
final class ContentNavReferenceArticle extends ContentNavIntent {
  const ContentNavReferenceArticle(this.targetId);
  final String targetId;
}

/// Open a subject card by catalog/offering id (if authorized & loaded).
final class ContentNavSubject extends ContentNavIntent {
  const ContentNavSubject(this.targetId);
  final String targetId;
}

/// Open a published vacancy by id (if authorized & loaded).
final class ContentNavVacancy extends ContentNavIntent {
  const ContentNavVacancy(this.targetId);
  final String targetId;
}

/// Open an absolute HTTPS URL externally.
final class ContentNavExternalHttps extends ContentNavIntent {
  const ContentNavExternalHttps(this.uri);
  final Uri uri;
}

/// Explicit no-op action (`kind: none`).
final class ContentNavNone extends ContentNavIntent {
  const ContentNavNone();
}

/// Unknown / forbidden / malformed — host must not navigate.
final class ContentNavDisabled extends ContentNavIntent {
  const ContentNavDisabled();
}

/// Resolve structured `action` and/or legacy `cta_route` / `cta_url`.
///
/// When [action] is present (even if invalid), legacy fields are ignored so a
/// forbidden structured action cannot fall back to a looser legacy CTA.
class ContentNavResolver {
  const ContentNavResolver._();

  static const List<String> allowedLegacyRoutePrefixes = <String>[
    '/diary',
    '/my-diary',
    '/info',
    '/profile',
    '/schedule',
    '/home',
    '/learning',
    '/help',
  ];

  static ContentNavIntent resolve({
    Map<String, dynamic>? action,
    String? ctaRoute,
    String? ctaUrl,
  }) {
    if (action != null) {
      return resolveAction(action);
    }
    return resolveLegacy(ctaRoute: ctaRoute, ctaUrl: ctaUrl);
  }

  static const Set<String> _allowedActionKeys = {
    'kind',
    'screen_key',
    'target_id',
    'url',
  };

  /// Resolve a schema-v2 structured action object.
  static ContentNavIntent resolveAction(Map<String, dynamic> action) {
    for (final key in action.keys) {
      if (!_allowedActionKeys.contains(key)) {
        return const ContentNavDisabled();
      }
    }

    // Present allowlisted fields must be non-empty strings (never coerced away).
    final kind = _requiredActionString(action, 'kind');
    if (kind == null) return const ContentNavDisabled();
    if (_invalidPresentActionField(action, 'screen_key') ||
        _invalidPresentActionField(action, 'target_id') ||
        _invalidPresentActionField(action, 'url')) {
      return const ContentNavDisabled();
    }

    final screenKey = _optionalActionString(action, 'screen_key');
    final targetId = _optionalActionString(action, 'target_id');
    final url = _optionalActionString(action, 'url');

    switch (kind) {
      case 'none':
        if (screenKey != null || targetId != null || url != null) {
          return const ContentNavDisabled();
        }
        return const ContentNavNone();
      case 'app_screen':
        if (targetId != null || url != null) return const ContentNavDisabled();
        return _screenKeyToIntent(screenKey);
      case 'reference_article':
        if (screenKey != null || url != null) return const ContentNavDisabled();
        if (!_isUuid(targetId)) return const ContentNavDisabled();
        return ContentNavReferenceArticle(targetId!);
      case 'subject':
        if (screenKey != null || url != null) return const ContentNavDisabled();
        if (!_isUuid(targetId)) return const ContentNavDisabled();
        return ContentNavSubject(targetId!);
      case 'vacancy':
        if (screenKey != null || url != null) return const ContentNavDisabled();
        if (!_isUuid(targetId)) return const ContentNavDisabled();
        return ContentNavVacancy(targetId!);
      case 'external_url':
        if (screenKey != null || targetId != null) {
          return const ContentNavDisabled();
        }
        final uri = tryParseSafeHttpsUri(url);
        if (uri == null) return const ContentNavDisabled();
        return ContentNavExternalHttps(uri);
      default:
        return const ContentNavDisabled();
    }
  }

  /// Returns true when [key] is present but not a non-empty String.
  static bool _invalidPresentActionField(
    Map<String, dynamic> action,
    String key,
  ) {
    if (!action.containsKey(key)) return false;
    final value = action[key];
    return value is! String || value.trim().isEmpty;
  }

  static String? _requiredActionString(
    Map<String, dynamic> action,
    String key,
  ) {
    if (!action.containsKey(key)) return null;
    final value = action[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _optionalActionString(
    Map<String, dynamic> action,
    String key,
  ) {
    if (!action.containsKey(key)) return null;
    final value = action[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Resolve legacy projected `cta_route` / `cta_url` (mutually exclusive).
  static ContentNavIntent resolveLegacy({
    String? ctaRoute,
    String? ctaUrl,
  }) {
    final route = ctaRoute?.trim();
    final url = ctaUrl?.trim();
    final hasRoute = route != null && route.isNotEmpty;
    final hasUrl = url != null && url.isNotEmpty;
    if (hasRoute && hasUrl) return const ContentNavDisabled();
    if (!hasRoute && !hasUrl) return const ContentNavNone();

    if (hasUrl) {
      final uri = tryParseSafeHttpsUri(url);
      if (uri == null) return const ContentNavDisabled();
      return ContentNavExternalHttps(uri);
    }

    if (!_isAllowedLegacyRoute(route!)) return const ContentNavDisabled();
    return legacyRouteToIntent(route);
  }

  /// Map an allowlisted legacy route to a typed intent.
  static ContentNavIntent legacyRouteToIntent(String route) {
    final normalized = route.trim();
    if (normalized == '/home' || normalized.startsWith('/home/')) {
      return const ContentNavAppTab(ContentAppTab.home);
    }
    if (normalized == '/profile' || normalized.startsWith('/profile/')) {
      return const ContentNavAppTab(ContentAppTab.profile);
    }
    if (normalized == '/schedule' || normalized.startsWith('/schedule/')) {
      return const ContentNavAppTab(ContentAppTab.schedule);
    }
    if (normalized == '/learning' || normalized.startsWith('/learning/')) {
      return const ContentNavAppTab(ContentAppTab.learning);
    }
    if (normalized == '/info' ||
        normalized.startsWith('/info/') ||
        normalized == '/help' ||
        normalized.startsWith('/help/')) {
      return const ContentNavAppTab(ContentAppTab.info);
    }
    if (normalized == '/diary' ||
        normalized.startsWith('/diary/') ||
        normalized == '/my-diary' ||
        normalized.startsWith('/my-diary/')) {
      return const ContentNavDiary();
    }
    return const ContentNavDisabled();
  }

  /// Absolute https URI with non-empty host and no user-info.
  static Uri? tryParseSafeHttpsUri(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.length > 500) return null;
    if (trimmed.startsWith('//')) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    if (!uri.hasScheme || uri.scheme.toLowerCase() != 'https') return null;
    if (!uri.hasAuthority) return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (uri.host.isEmpty) return null;
    if (uri.host.contains(' ')) return null;
    return uri;
  }

  static ContentNavIntent _screenKeyToIntent(String? screenKey) {
    switch (screenKey) {
      case 'home':
        return const ContentNavAppTab(ContentAppTab.home);
      case 'info':
      case 'help':
        return const ContentNavAppTab(ContentAppTab.info);
      case 'learning':
        return const ContentNavAppTab(ContentAppTab.learning);
      case 'schedule':
        return const ContentNavAppTab(ContentAppTab.schedule);
      case 'profile':
        return const ContentNavAppTab(ContentAppTab.profile);
      case 'diary':
        return const ContentNavDiary();
      default:
        return const ContentNavDisabled();
    }
  }

  static bool _isAllowedLegacyRoute(String route) {
    if (route.contains(RegExp(r'\s')) || route.length > 300) return false;
    if (!route.startsWith('/')) return false;
    for (final prefix in allowedLegacyRoutePrefixes) {
      if (route == prefix || route.startsWith('$prefix/')) return true;
    }
    return false;
  }

  static final RegExp _uuidRe = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool _isUuid(String? value) =>
      value != null && _uuidRe.hasMatch(value);
}
