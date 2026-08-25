/// Shared helpers for Stage 14.1.1 working-draft edit UX.
bool parseHasWorkingDraft(Map<String, dynamic> json) {
  final raw = json['has_working_draft'] ?? json['hasWorkingDraft'];
  if (raw is bool) return raw;
  if (raw == null) return false;
  final text = raw.toString().trim().toLowerCase();
  return text == 'true' || text == '1';
}

Map<String, dynamic>? parseWorkingDraftMap(Map<String, dynamic> json) {
  final raw = json['working_draft'] ?? json['workingDraft'];
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return null;
}

int? parseWorkingDraftRowVersion(Map<String, dynamic>? draft) {
  if (draft == null) return null;
  final raw = draft['row_version'] ?? draft['rowVersion'];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '');
}
