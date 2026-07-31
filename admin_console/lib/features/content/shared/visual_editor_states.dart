import 'package:flutter/material.dart';

/// Shared loading indicator for visual content editors.
class VisualEditorLoadingState extends StatelessWidget {
  const VisualEditorLoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

/// Shared error state with retry action.
class VisualEditorErrorState extends StatelessWidget {
  const VisualEditorErrorState({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder when no item is selected or the current tab is empty.
class VisualEditorEmptyState extends StatelessWidget {
  const VisualEditorEmptyState({
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Info or error banner used under the editor toolbar.
class VisualEditorBanner extends StatelessWidget {
  const VisualEditorBanner.info({required this.text, super.key})
    : icon = Icons.info_outline,
      color = const Color(0xFFEFF4FF),
      border = const Color(0xFFC7D6F5),
      iconColor = const Color(0xFF2F5AA8),
      textColor = const Color(0xFF2F5AA8);

  const VisualEditorBanner.error({required this.text, super.key})
    : icon = Icons.error_outline,
      color = const Color(0xFFFDE7E9),
      border = const Color(0xFFF3B4BB),
      iconColor = const Color(0xFFB3261E),
      textColor = const Color(0xFF8C1D18);

  final String text;
  final IconData icon;
  final Color color;
  final Color border;
  final Color iconColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
