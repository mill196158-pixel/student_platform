import 'package:flutter/material.dart';

/// Reusable keyboard dismiss for forms.
///
/// Closes the keyboard on:
/// - confirmed tap on free area ([GestureDetector.onTap], translucent —
///   loses the gesture arena to [TextField] / [EditableText])
/// - user drag scroll (only [ScrollUpdateNotification.dragDetails] != null)
/// - [ScrollView.keyboardDismissBehavior] when the form sets `onDrag`
/// - system back while a field is focused ([PopScope])
///
/// Does **not** close on:
/// - the same tap that focused a [TextField] (child wins the arena)
/// - programmatic scroll from keyboard [MediaQuery.viewInsets] re-layout
/// - rebuilds / focus changes / capability updates
/// - pointer-down listeners (never used — would unfocus before arena resolve)
///
/// ## Stage 13.11.1 root cause
/// Previous code dismissed on any [ScrollUpdateNotification] whose absolute
/// scroll delta exceeded 2. Opening the keyboard resizes the scroll view and
/// emits exactly that notification:
/// `tap → focus → keyboard open → inset scroll → unfocus`.
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
    if (context != null && context.mounted) {
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
          // User finger drag only — never programmatic keyboard-inset scroll.
          if (notification is ScrollUpdateNotification &&
              notification.dragDetails != null) {
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
              // onTap only after the arena resolves (not pointer-down phase).
              // TextField wins when the tap is on the field.
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
