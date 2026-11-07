import 'package:flutter/widgets.dart';

/// Indicates that the surrounding local-only list paints reaction chips.
class LocalReactionOverlayScope extends InheritedWidget {
  const LocalReactionOverlayScope({super.key, required super.child});
  static bool active(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LocalReactionOverlayScope>() != null;
  @override
  bool updateShouldNotify(LocalReactionOverlayScope oldWidget) => false;
}
