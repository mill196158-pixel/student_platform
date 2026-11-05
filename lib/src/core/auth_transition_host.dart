import 'package:flutter/widgets.dart';
import 'auth_transition_coordinator.dart';

/// Passive owner of app-level transition coordination; does not call auth.
class AuthTransitionHost extends StatefulWidget {
  const AuthTransitionHost({super.key, required this.child});
  final Widget child;
  static AuthTransitionCoordinator? maybeRead(BuildContext context) => context
      .getInheritedWidgetOfExactType<_AuthTransitionProvider>()
      ?.coordinator;
  @override
  State<AuthTransitionHost> createState() => _AuthTransitionHostState();
}

class _AuthTransitionHostState extends State<AuthTransitionHost> {
  final _coordinator = AuthTransitionCoordinator();
  @override
  void dispose() {
    _coordinator.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _AuthTransitionProvider(coordinator: _coordinator, child: widget.child);
}

class _AuthTransitionProvider extends InheritedWidget {
  const _AuthTransitionProvider(
      {required this.coordinator, required super.child});
  final AuthTransitionCoordinator coordinator;
  @override
  bool updateShouldNotify(_AuthTransitionProvider oldWidget) =>
      !identical(coordinator, oldWidget.coordinator);
}
