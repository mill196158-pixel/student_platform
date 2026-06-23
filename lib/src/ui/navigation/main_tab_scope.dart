import 'package:flutter/material.dart';

enum MainTab {
  home,
  info,
  learning,
  schedule,
  profile,
}

class MainTabScope extends InheritedWidget {
  const MainTabScope({
    super.key,
    required this.switchTo,
    required super.child,
  });

  final void Function(MainTab tab) switchTo;

  static MainTabScope? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MainTabScope>();
  }

  static void switchToTab(BuildContext context, MainTab tab) {
    maybeOf(context)?.switchTo(tab);
  }

  @override
  bool updateShouldNotify(MainTabScope oldWidget) =>
      switchTo != oldWidget.switchTo;
}
