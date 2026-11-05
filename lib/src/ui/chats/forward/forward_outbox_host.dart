import 'package:flutter/widgets.dart';

import '../../../core/auth_session_scope.dart';
import '../../../core/auth_session_scope_host.dart';
import 'forward_outbox_preferences.dart';
import 'forward_outbox_store.dart';

/// Passive owner: it never reads or removes an outbox entry by itself.
class ForwardOutboxHost extends StatefulWidget {
  const ForwardOutboxHost(
      {super.key, required this.child, this.source, this.storage});
  final Widget child;
  @visibleForTesting
  final AuthSessionScope? source;
  @visibleForTesting
  final ForwardOutboxStorage? storage;

  static ForwardOutboxStore? maybeRead(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ForwardOutboxProvider>()?.store;

  @override
  State<ForwardOutboxHost> createState() => _ForwardOutboxHostState();
}

class _ForwardOutboxHostState extends State<ForwardOutboxHost> {
  late final ForwardOutboxCoordinator _coordinator;
  AuthSessionScope? _scope;
  ForwardOutboxStore? _store;

  @override
  void initState() {
    super.initState();
    _coordinator = ForwardOutboxCoordinator(
        widget.storage ?? PreferencesForwardOutboxStorage());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant ForwardOutboxHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.source, oldWidget.source)) _bind();
    assert(identical(widget.storage, oldWidget.storage),
        'ForwardOutboxHost storage must remain stable for its lifetime');
  }

  void _bind() {
    final source = widget.source ?? AuthSessionScopeHost.maybeOf(context);
    if (identical(source, _scope)) return;
    _store?.dispose();
    _scope = source;
    _store = source == null ? null : ForwardOutboxStore(source, _coordinator);
  }

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return store == null
        ? widget.child
        : _ForwardOutboxProvider(store: store, child: widget.child);
  }
}

class _ForwardOutboxProvider extends InheritedWidget {
  const _ForwardOutboxProvider({required this.store, required super.child});
  final ForwardOutboxStore store;
  @override
  bool updateShouldNotify(_ForwardOutboxProvider oldWidget) =>
      !identical(store, oldWidget.store);
}
