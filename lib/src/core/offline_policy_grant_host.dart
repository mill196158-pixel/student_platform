import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import 'auth_session_scope.dart';
import 'auth_session_scope_host.dart';
import 'offline_policy_grant.dart';
import 'offline_policy_grant_store.dart';

/// Passive storage owner. It neither checks policy nor grants offline access.
class OfflinePolicyGrantAccess {
  const OfflinePolicyGrantAccess(
      this.scope, this.store, this._currentSession, this._issuer);
  final AuthSessionScope scope;
  final OfflinePolicyGrantStore store;
  final Session? Function() _currentSession;
  final String _issuer;

  OfflineSessionBinding? currentBinding() {
    final session = _currentSession();
    return session == null
        ? null
        : OfflineSessionBinding.fromSession(session, _issuer);
  }
}

class OfflinePolicyGrantHost extends StatefulWidget {
  const OfflinePolicyGrantHost(
      {super.key,
      required this.child,
      this.source,
      this.currentSession,
      this.storage,
      this.issuer});
  final Widget child;
  @visibleForTesting
  final AuthSessionScope? source;
  @visibleForTesting
  final Session? Function()? currentSession;
  @visibleForTesting
  final OfflineGrantStorage? storage;
  @visibleForTesting
  final String? issuer;

  static OfflinePolicyGrantAccess? maybeRead(BuildContext context) => context
      .getInheritedWidgetOfExactType<_OfflinePolicyGrantProvider>()
      ?.access;

  @override
  State<OfflinePolicyGrantHost> createState() => _OfflinePolicyGrantHostState();
}

class _OfflinePolicyGrantHostState extends State<OfflinePolicyGrantHost> {
  late final OfflineGrantCoordinator _coordinator;
  AuthSessionScope? _scope;
  OfflinePolicyGrantAccess? _access;

  @override
  void initState() {
    super.initState();
    _coordinator = OfflineGrantCoordinator(
        widget.storage ?? PreferencesOfflineGrantStorage());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void didUpdateWidget(covariant OfflinePolicyGrantHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source) ||
        oldWidget.currentSession != widget.currentSession ||
        oldWidget.issuer != widget.issuer) _bind(force: true);
  }

  void _bind({bool force = false}) {
    final scope = widget.source ?? AuthSessionScopeHost.maybeOf(context);
    if (!force && identical(scope, _scope)) return;
    _access?.store.dispose();
    _scope = scope;
    if (scope == null) {
      _access = null;
      return;
    }
    final issuer = widget.issuer ??
        '${SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '')}/auth/v1';
    final Session? Function() readSession = widget.currentSession ??
        () => Supabase.instance.client.auth.currentSession;
    OfflineSessionBinding? binding() {
      final session = readSession();
      return session == null
          ? null
          : OfflineSessionBinding.fromSession(session, issuer);
    }

    final store = OfflinePolicyGrantStore(
        session: scope, currentBinding: binding, coordinator: _coordinator);
    _access = OfflinePolicyGrantAccess(scope, store, readSession, issuer);
  }

  @override
  void dispose() {
    _access?.store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final access = _access;
    return access == null
        ? widget.child
        : _OfflinePolicyGrantProvider(access: access, child: widget.child);
  }
}

class _OfflinePolicyGrantProvider extends InheritedWidget {
  const _OfflinePolicyGrantProvider(
      {required this.access, required super.child});
  final OfflinePolicyGrantAccess access;
  @override
  bool updateShouldNotify(_OfflinePolicyGrantProvider oldWidget) =>
      !identical(access, oldWidget.access);
}
