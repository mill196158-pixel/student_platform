import 'package:flutter/material.dart';
import '../composer.dart';

/// Keeps the chat viewport stable while the composer waits for its session.
class ChatComposerGate extends StatelessWidget {
  const ChatComposerGate({
    super.key,
    required Widget child,
    this.status,
    this.onRetry,
  }) : child = child;

  const ChatComposerGate.placeholder({
    super.key,
    required String this.status,
    this.onRetry,
  }) : child = null;

  final Widget? child;
  final String? status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final blocked = status != null;
    final colors = Theme.of(context).colorScheme;
    final composer = child;
    if (composer == null) {
      return SizedBox(
        height: Composer.restingHeightOf(context),
        child: ColoredBox(
          color: colors.surface,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                12, 0, 12, Composer.bottomPaddingOf(context)),
            child: _statusLabel(colors),
          ),
        ),
      );
    }
    return Stack(
      children: [
        ExcludeFocus(
          excluding: blocked,
          child: ExcludeSemantics(
            excluding: blocked,
            child: IgnorePointer(
              ignoring: blocked,
              child: Opacity(opacity: blocked ? 0 : 1, child: composer),
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
                child: _statusLabel(colors),
              ),
            ),
          ),
      ],
    );
  }

  Widget _statusLabel(ColorScheme colors) {
    return Center(
      child: onRetry == null
          ? Semantics(
              liveRegion: true,
              child: Text(status!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant)),
            )
          : TextButton(
              onPressed: onRetry,
              child: Text(status!, textAlign: TextAlign.center)),
    );
  }
}
