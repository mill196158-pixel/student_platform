import 'package:flutter/material.dart';

/// Admin phone preview source (Stage 14.1.3).
///
/// [effectiveDraft] — whole in-memory snapshot: local edits → working draft →
/// published fields bound in controllers.
///
/// [publishedCanonical] — server-published payload only; ignores WD and unsaved
/// form state.
enum ContentPreviewMode { effectiveDraft, publishedCanonical }

extension ContentPreviewModeLabels on ContentPreviewMode {
  String get labelRu => switch (this) {
    ContentPreviewMode.effectiveDraft => 'С текущими правками',
    ContentPreviewMode.publishedCanonical => 'Как опубликовано',
  };
}

/// Segmented toggle for preview mode (Russian labels).
class ContentPreviewModeToggle extends StatelessWidget {
  const ContentPreviewModeToggle({
    super.key,
    required this.mode,
    required this.onChanged,
    this.enabled = true,
  });

  final ContentPreviewMode mode;
  final ValueChanged<ContentPreviewMode> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ContentPreviewMode>(
      segments: [
        for (final value in ContentPreviewMode.values)
          ButtonSegment(
            value: value,
            label: Text(value.labelRu, softWrap: false),
          ),
      ],
      selected: {mode},
      onSelectionChanged: enabled
          ? (value) {
              if (value.isEmpty) return;
              onChanged(value.first);
            }
          : null,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
