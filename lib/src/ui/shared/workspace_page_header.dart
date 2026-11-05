import 'package:flutter/material.dart';

/// A content-sized header that leaves room for long names and accessible text.
class WorkspacePageHeader extends StatelessWidget {
  const WorkspacePageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.supportingText,
    this.actions,
    this.compact = false,
  });

  final String title;
  final String? subtitle;
  final String? supportingText;
  final Widget? actions;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Назад',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurface, height: 1.25)),
                  for (final text in [subtitle, supportingText])
                    if (!compact && text != null && text.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                ],
              ),
            ),
            if (actions != null) ...[const SizedBox(width: 8), actions!],
          ],
        ),
      ),
    );
  }
}
