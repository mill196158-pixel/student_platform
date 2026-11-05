import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope.dart';

/// Owns one identity tracker for the lifetime of the application subtree.
class AuthSessionScopeHost extends StatefulWidget {
  const AuthSessionScopeHost(
      {super.key, required this.child, this.createScope});

  final Widget child;
  @visibleForTesting
  final AuthSessionScope Function()? createScope;

  static AuthSessionScope? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_AuthSessionScopeProvider>()
      ?.notifier;

  /// One-shot lookup for event handlers; does not subscribe the caller.
  static AuthSessionScope? maybeRead(BuildContext context) => context
      .getInheritedWidgetOfExactType<_AuthSessionScopeProvider>()
      ?.notifier;

  @override
  State<AuthSessionScopeHost> createState() => _AuthSessionScopeHostState();
}

class _AuthSessionScopeHostState extends State<AuthSessionScopeHost> {
  late final AuthSessionScope _scope;

  @override
  void initState() {
    super.initState();
    _scope = widget.createScope?.call() ?? _createProductionScope();
  }

  AuthSessionScope _createProductionScope() {
    final client = Supabase.instance.client;
    return AuthSessionScope(
      currentSession: () => client.auth.currentSession,
      authEvents: client.auth.onAuthStateChange,
    );
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AuthSessionScopeProvider(
        notifier: _scope,
        child: widget.child,
      );
}

class _AuthSessionScopeProvider extends InheritedNotifier<AuthSessionScope> {
  const _AuthSessionScopeProvider(
      {required super.notifier, required super.child});
}
