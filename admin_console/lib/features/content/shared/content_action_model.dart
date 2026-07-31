import 'package:student_ui/student_ui.dart';

/// Kind of tap action for content cards.
enum ContentActionKind {
  appScreen,
  referenceArticle,
  subject,
  vacancy,
  externalUrl,
  chat,
  none,
}

/// Chat target mode for schema-3 home promo actions.
/// Structured action selection stored in editors; projected to legacy routes in v1.
class ContentActionSelection {
  const ContentActionSelection({
    required this.kind,
    this.screenKey,
    this.targetId,
    this.url,
    this.chatTargetMode,
  });

  final ContentActionKind kind;
  final String? screenKey;
  final String? targetId;
  final String? url;

  /// When [kind] is [ContentActionKind.chat]: `chat_id` or `current_group_chat`.
  final String? chatTargetMode;

  ContentActionSelection copyWith({
    ContentActionKind? kind,
    String? screenKey,
    String? targetId,
    String? url,
    String? chatTargetMode,
    bool clearScreenKey = false,
    bool clearTargetId = false,
    bool clearUrl = false,
    bool clearChatTargetMode = false,
  }) {
    return ContentActionSelection(
      kind: kind ?? this.kind,
      screenKey: clearScreenKey ? null : (screenKey ?? this.screenKey),
      targetId: clearTargetId ? null : (targetId ?? this.targetId),
      url: clearUrl ? null : (url ?? this.url),
      chatTargetMode: clearChatTargetMode
          ? null
          : (chatTargetMode ?? this.chatTargetMode),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ContentActionSelection &&
        other.kind == kind &&
        other.screenKey == screenKey &&
        other.targetId == targetId &&
        other.url == url &&
        other.chatTargetMode == chatTargetMode;
  }

  @override
  int get hashCode =>
      Object.hash(kind, screenKey, targetId, url, chatTargetMode);
}

/// Human label for each action kind.
String contentActionKindLabelRu(ContentActionKind kind) {
  return switch (kind) {
    ContentActionKind.appScreen => 'Открыть экран приложения',
    ContentActionKind.referenceArticle => 'Открыть статью справочника',
    ContentActionKind.subject => 'Открыть предмет',
    ContentActionKind.vacancy => 'Открыть вакансию',
    ContentActionKind.externalUrl => 'Открыть внешний сайт',
    ContentActionKind.chat => 'Открыть чат',
    ContentActionKind.none => 'Без действия',
  };
}

/// Allowlisted in-app screen keys with Russian labels.
const Map<String, String> kContentAppScreenLabels = {
  'home': 'Главная',
  'diary': 'Дневник',
  'schedule': 'Расписание',
  'info': 'Справка / база знаний',
  'profile': 'Профиль',
  'learning': 'Обучение',
};

/// Legacy mobile route for v1 projection from structured action.
///
/// Must match `private.content_legacy_route_for_screen` (Stage 14.1.2 follow-up)
/// so structured `action` + `cta_route` never raise `action_legacy_route_conflict`.
String? legacyCtaRouteForAction(ContentActionSelection action) {
  if (action.kind != ContentActionKind.appScreen) return null;
  final key = action.screenKey;
  if (key == null || key.isEmpty) return null;
  return switch (key) {
    'home' => '/home',
    'diary' => '/my-diary',
    'schedule' => '/schedule',
    'info' || 'help' => '/help',
    'profile' => '/profile',
    'learning' => '/learning',
    _ => null,
  };
}

/// Reverse-map a legacy route to a screen key when possible.
String? screenKeyFromLegacyRoute(String? route) {
  if (route == null || route.isEmpty) return null;
  final normalized = route.trim();
  return switch (normalized) {
    '/' || '/home' => 'home',
    '/my-diary' || '/diary' => 'diary',
    '/schedule' => 'schedule',
    '/help' || '/info' => 'info',
    '/profile' => 'profile',
    '/learning' => 'learning',
    _ => null,
  };
}

/// Build selection from legacy cta_route / cta_url fields (home promo v1).
ContentActionSelection contentActionFromLegacy({
  required String ctaAction,
  required String ctaRoute,
  required String ctaUrl,
}) {
  if (ctaAction == 'url' && ctaUrl.trim().isNotEmpty) {
    return ContentActionSelection(
      kind: ContentActionKind.externalUrl,
      url: ctaUrl.trim(),
    );
  }
  final screenKey = screenKeyFromLegacyRoute(ctaRoute.trim());
  if (screenKey != null) {
    return ContentActionSelection(
      kind: ContentActionKind.appScreen,
      screenKey: screenKey,
    );
  }
  if (ctaRoute.trim().isNotEmpty) {
    // Unknown legacy route — keep route in technical panel; show as info screen.
    return ContentActionSelection(
      kind: ContentActionKind.appScreen,
      screenKey: 'info',
    );
  }
  return const ContentActionSelection(kind: ContentActionKind.none);
}

/// Apply structured selection back to legacy route/url controllers.
void applyContentActionToLegacy({
  required ContentActionSelection action,
  required void Function(String ctaAction) onCtaActionChanged,
  required void Function(String route) onCtaRouteChanged,
  required void Function(String url) onCtaUrlChanged,
}) {
  switch (action.kind) {
    case ContentActionKind.externalUrl:
      onCtaActionChanged('url');
      onCtaUrlChanged(action.url?.trim() ?? '');
      onCtaRouteChanged('');
    case ContentActionKind.appScreen:
      onCtaActionChanged('route');
      onCtaRouteChanged(legacyCtaRouteForAction(action) ?? '');
      onCtaUrlChanged('');
    case ContentActionKind.none:
      onCtaActionChanged('route');
      onCtaRouteChanged('');
      onCtaUrlChanged('');
    case ContentActionKind.chat:
      onCtaActionChanged('route');
      onCtaRouteChanged('');
      onCtaUrlChanged('');
    case ContentActionKind.referenceArticle:
    case ContentActionKind.subject:
    case ContentActionKind.vacancy:
      // v2 structured targets — v1 leaves route/url empty until server supports.
      onCtaActionChanged('route');
      onCtaRouteChanged('');
      onCtaUrlChanged('');
  }
}

/// Returns null when valid; Russian error message when invalid.
String? validateContentExternalUrl(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return 'Укажите URL';
  }
  final trimmed = raw.trim();
  if (ContentNavResolver.tryParseSafeHttpsUri(trimmed) == null) {
    if (trimmed.length > ContentNavResolver.maxSafeHttpsUrlLength) {
      return 'Ссылка слишком длинная (максимум ${ContentNavResolver.maxSafeHttpsUrlLength} символов)';
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('http:')) {
      return 'Разрешены только HTTPS-ссылки';
    }
    return 'Некорректный URL';
  }
  return null;
}

/// Option row for async target pickers (article / subject / vacancy).
class ContentActionTargetOption {
  const ContentActionTargetOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// Wire `action.kind` for schema v2 payloads.
String contentActionKindWire(ContentActionKind kind) {
  return switch (kind) {
    ContentActionKind.appScreen => 'app_screen',
    ContentActionKind.referenceArticle => 'reference_article',
    ContentActionKind.subject => 'subject',
    ContentActionKind.vacancy => 'vacancy',
    ContentActionKind.externalUrl => 'external_url',
    ContentActionKind.chat => 'chat',
    ContentActionKind.none => 'none',
  };
}

/// Structured action object for schema v2 `payload.action`.
Map<String, dynamic> contentActionToWire(ContentActionSelection action) {
  return {
    'kind': contentActionKindWire(action.kind),
    if (action.screenKey != null && action.screenKey!.trim().isNotEmpty)
      'screen_key': action.screenKey!.trim(),
    if (action.kind == ContentActionKind.chat &&
        action.chatTargetMode != null &&
        action.chatTargetMode!.trim().isNotEmpty)
      'target_mode': action.chatTargetMode!.trim(),
    if (action.targetId != null && action.targetId!.trim().isNotEmpty)
      'target_id': action.targetId!.trim(),
    if (action.url != null && action.url!.trim().isNotEmpty)
      'url': action.url!.trim(),
  };
}

/// Parse structured action from server/working-draft payload.
ContentActionSelection contentActionFromWire(Object? raw) {
  if (raw is! Map) {
    return const ContentActionSelection(kind: ContentActionKind.none);
  }
  final kind = switch (raw['kind']?.toString()) {
    'app_screen' => ContentActionKind.appScreen,
    'reference_article' => ContentActionKind.referenceArticle,
    'subject' => ContentActionKind.subject,
    'vacancy' => ContentActionKind.vacancy,
    'external_url' => ContentActionKind.externalUrl,
    'chat' => ContentActionKind.chat,
    'none' => ContentActionKind.none,
    _ => ContentActionKind.none,
  };
  return ContentActionSelection(
    kind: kind,
    screenKey: raw['screen_key']?.toString(),
    targetId: raw['target_id']?.toString(),
    url: raw['url']?.toString(),
    chatTargetMode: raw['target_mode']?.toString(),
  );
}

/// True when payload uses v2-only publish features (server gate defaults OFF).
bool contentWireUsesV2PublishFeatures(Map<String, dynamic> payload) {
  final slot = payload['home_slot']?.toString();
  if (slot != null && slot.isNotEmpty && slot != 'after_assignments') {
    return true;
  }
  final variant = payload['card_variant']?.toString();
  if (variant != null && variant.isNotEmpty && variant != 'gradient_text') {
    return true;
  }
  if (payload.containsKey('action')) return true;
  return false;
}

/// Shown when publish RPC rejects schema v2 until Mobile release.
const kVisualStudioV2PublishBlockedMessageRu =
    'Сохранить черновик можно, но опубликовать карточку с новым оформлением '
    'пока нельзя — приложение для студентов ещё не обновлено.';
