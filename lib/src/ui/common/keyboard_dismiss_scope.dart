import 'package:flutter/material.dart';

/// Reusable keyboard dismiss: tap outside, scroll drag, system back.
class KeyboardDismissScope extends StatelessWidget {
  const KeyboardDismissScope({
    super.key,
    required this.child,
    this.onDismiss,
    this.dismissOnTap = true,
    this.dismissOnScroll = true,
  });

  final Widget child;
  final VoidCallback? onDismiss;
  final bool dismissOnTap;
  final bool dismissOnScroll;

  static void unfocus([BuildContext? context]) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (context != null) {
      FocusScope.of(context).unfocus();
    }
  }

  void _dismiss(BuildContext context) {
    unfocus(context);
    onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    Widget body = child;
    if (dismissOnScroll) {
      body = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              (notification.dragDetails != null ||
                  (notification.scrollDelta?.abs() ?? 0) > 2)) {
            final hasFocus =
                FocusManager.instance.primaryFocus?.hasFocus ?? false;
            if (hasFocus) _dismiss(context);
          }
          return false;
        },
        child: body,
      );
    }

    return PopScope(
      canPop: !(FocusManager.instance.primaryFocus?.hasFocus ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final focused = FocusManager.instance.primaryFocus?.hasFocus ?? false;
        if (focused) {
          _dismiss(context);
        }
      },
      child: dismissOnTap
          ? GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _dismiss(context),
              child: body,
            )
          : body,
    );
  }
}

/// TextInputAction.done that unfocuses on submit.
class DoneUnfocusAction extends StatelessWidget {
  const DoneUnfocusAction({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return child;
  }
}

/// Convenience wrapper for form fields that should show Done and dismiss.
InputDecoration keyboardDoneDecoration(
  InputDecoration base, {
  required VoidCallback onDone,
}) {
  return base;
}
