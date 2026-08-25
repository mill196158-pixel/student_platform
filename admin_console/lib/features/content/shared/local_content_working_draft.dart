// Shared local simulation helpers for Stage 14.1.1 content working drafts.

class LocalContentWorkingDraftException implements Exception {
  const LocalContentWorkingDraftException(this.message);

  final String message;

  @override
  String toString() => message;
}

void assertNoLocalWorkingDraft(
  Map<String, Object?> drafts,
  String id, {
  String message =
      'Сначала опубликуйте или отмените черновик изменений (working_draft_exists).',
}) {
  if (drafts.containsKey(id)) {
    throw LocalContentWorkingDraftException(message);
  }
}

int? parseDraftRowVersion(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '');
}

List<String> parseDraftIdList(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .map((e) => e?.toString().trim() ?? '')
      .where((e) => e.isNotEmpty)
      .toList();
}

DateTime? parseDraftDate(Object? raw) {
  if (raw == null) return null;
  return DateTime.tryParse(raw.toString());
}
