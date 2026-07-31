import 'package:flutter/material.dart';

/// Pre-permission UI. System permission is requested only after "Включить".
Future<bool?> showPushPermissionPrompt(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final cs = theme.colorScheme;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            8,
            24,
            20 + MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.notifications_active_outlined,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Не пропускайте важное',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Сообщим о личных сообщениях, заявках в друзья, заданиях и изменениях в учёбе.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: cs.onSurface.withValues(alpha: 0.74),
                ),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: () => Navigator.of(sheetContext).pop(true),
                child: const Text('Включить уведомления'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(false),
                child: const Text('Не сейчас'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
