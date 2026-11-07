import 'package:flutter/material.dart';
import 'package:student_platform/src/core/pinned_media_availability.dart';

/// Visible even in a document-only chat; saved legacy files remain usable.
class PinnedMediaStatusHost extends StatelessWidget {
  const PinnedMediaStatusHost({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PinnedMediaAvailabilityState>(
    valueListenable: PinnedMediaAvailability.state,
    builder: (context, state, _) => Stack(children: [
      child,
      if (state == PinnedMediaAvailabilityState.unavailable)
        Positioned(top: 0, left: 12, right: 12, child: SafeArea(bottom: false,
          child: Material(color: Theme.of(context).colorScheme.surfaceContainerHighest,
            elevation: 3, borderRadius: BorderRadius.circular(14),
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(children: [
                Expanded(child: Text('Вложения временно недоступны',
                    style: Theme.of(context).textTheme.bodySmall)),
                TextButton(onPressed: PinnedMediaAvailability.retry, child: const Text('Повторить')),
              ]))))),
    ]),
  );
}
