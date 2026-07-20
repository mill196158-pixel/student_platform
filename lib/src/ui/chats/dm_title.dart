/// Neutral DM title when peer profile is unknown / empty / legacy RPC fallback.
const kDmTitleFallback = 'Пользователь';

/// Legacy technical title from older `get_my_chat_summaries` RPC.
const kDmTitleLegacyFallback = 'Личный чат';

/// True when [title] is empty or a technical/neutral placeholder that should be
/// replaced by a profile lookup (`peerId` / `users` row).
bool isUnresolvedDmTitle(String? title) {
  final t = (title ?? '').trim();
  return t.isEmpty || t == kDmTitleLegacyFallback || t == kDmTitleFallback;
}

/// Map empty / legacy technical DM titles to [kDmTitleFallback].
String normalizeDmTitle(String? title) {
  final t = (title ?? '').trim();
  if (t.isEmpty || t == kDmTitleLegacyFallback) return kDmTitleFallback;
  return t;
}
