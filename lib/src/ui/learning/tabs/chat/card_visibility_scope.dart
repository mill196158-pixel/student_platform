import 'package:flutter/widgets.dart';

/// UI-only report from an action-card row to the message list. It never
/// mutates messages or cached server data.
class ChatCardVisibilityScope extends InheritedWidget {
  const ChatCardVisibilityScope({super.key, required this.report, required super.child});

  final void Function(bool visible) report;

  static void setVisible(BuildContext context, bool visible) {
    final scope = context.dependOnInheritedWidgetOfExactType<ChatCardVisibilityScope>();
    if (scope == null) return;
    // Card builds can run while the list is laying out. Notify after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => scope.report(visible));
  }

  @override
  bool updateShouldNotify(ChatCardVisibilityScope oldWidget) => false;
}
