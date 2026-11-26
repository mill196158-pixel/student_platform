import 'package:flutter/material.dart';

/// Keeps the chat viewport stable while the composer waits for its session.
class ChatComposerGate extends StatelessWidget {
  const ChatComposerGate({
    super.key,
    required this.child,
    this.status,
    this.onRetry,
  });

  final Widget child;
  final String? status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final blocked = status != null;
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ExcludeFocus(
          excluding: blocked,
          child: ExcludeSemantics(
            excluding: blocked,
            child: IgnorePointer(
              ignoring: blocked,
              child: Opacity(opacity: blocked ? 0 : 1, child: child),
            ),
          ),
        ),
        if (blocked)
          Positioned.fill(
            child: ColoredBox(
              color: colors.surface,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(
                  child: onRetry == null
                      ? Semantics(
                          liveRegion: true,
                          child: Text(
                            status!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        )
                      : TextButton(onPressed: onRetry, child: Text(status!)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
