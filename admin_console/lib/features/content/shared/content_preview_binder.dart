import 'content_preview_mode.dart';

/// Whether Admin preview should overlay the in-memory live draft snapshot.
///
/// Atomic snapshot rule (whole payload, not field-by-field):
/// 1. Local unsaved controller state (when [dirty]).
/// 2. Working draft row already bound in editors.
/// 3. Published canonical payload.
/// 4. Eligible demo seed (Mobile only; Admin [publishedCanonical] skips demo).
///
/// [publishedCanonical] never overlays — preview reads persisted published only.
bool shouldOverlayLiveDraft({
  required bool isDraft,
  required bool editingWorkingDraft,
  required bool dirty,
  required ContentPreviewMode mode,
}) {
  if (mode == ContentPreviewMode.publishedCanonical) return false;
  return isDraft || editingWorkingDraft || dirty;
}
