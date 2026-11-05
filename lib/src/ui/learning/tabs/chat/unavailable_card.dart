import 'package:flutter/material.dart';

/// The chat message exists, but its associated action is unavailable.
class UnavailableChatCard extends StatelessWidget {
  const UnavailableChatCard({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Карточка недоступна',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}
