import 'package:flutter/widgets.dart';

import 'auth_session_scope.dart';
import 'auth_session_scope_host.dart';
import 'session_capabilities.dart';

/// Owns capabilities, but never authorizes a session or changes a route.
class SessionCapabilitiesHost extends StatefulWidget {
  const SessionCapabilitiesHost({super.key, required this.child, this.source});
  final Widget child;
  @visibleForTesting
  final AuthSessionScope? source;

  static SessionCapabilities? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_CapabilitiesProvider>()
      ?.notifier;

  static SessionCapabilities? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_CapabilitiesProvider>()?.notifier;

  @override
  State<SessionCapabilitiesHost> createState() =>
      _SessionCapabilitiesHostState();
}

class _SessionCapabilitiesHostState extends State<SessionCapabilitiesHost> {
  AuthSessionScope? _source;
  SessionCapabilities? _capabilities;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant SessionCapabilitiesHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) _bind();
  }

  void _bind() {
    final source = widget.source ?? AuthSessionScopeHost.maybeOf(context);
    if (identical(source, _source)) return;
    _capabilities?.dispose();
    _source = source;
    _capabilities = source == null ? null : SessionCapabilities(source);
  }

  @override
  void dispose() {
    _capabilities?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = _capabilities;
    return capabilities == null
        ? widget.child
        : _CapabilitiesProvider(notifier: capabilities, child: widget.child);
  }
}

class _CapabilitiesProvider extends InheritedNotifier<SessionCapabilities> {
  const _CapabilitiesProvider({required super.notifier, required super.child});
}
