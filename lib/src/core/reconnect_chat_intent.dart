import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope.dart';
import 'coordinated_refresh_client.dart';

/// In-memory navigation only. A ticket never authorizes access.
class ReconnectChatIntent {
  ReconnectChatIntent._();
  static final instance = ReconnectChatIntent._();
  AuthSessionScope? _source;
  RefreshAdmissionClient? _gate;
  Session? Function()? _session;
  _Intent? _intent;
  int _epoch = 0;
  int navigationRevision = 0;
  final Set<Route<dynamic>> _routes = {};

  void bind(AuthSessionScope scope, RefreshAdmissionClient gate,
      Session? Function() currentSession) {
    cancel();
    _source = scope; _gate = gate; _session = currentSession;
  }

  Object? register({required AuthSessionScope scope, required Route<dynamic> route,
    required String chatId, required String targetId, required bool dm}) {
    cancel();
    try {
    final gate = _gate, getSession = _session;
    final owner = scope.capture(), session = getSession?.call();
    if (!identical(scope, _source) || gate == null || getSession == null ||
        owner == null || session == null || chatId.isEmpty || targetId.isEmpty ||
        gate.activeAuthOperations != 0 || gate.refreshEntrants != 0 ||
        !scope.matchesSession(owner, session)) return null;
    final marker = Object();
    final candidate = _Intent(marker, scope, owner, route, chatId, targetId, dm,
        gate, getSession, session, scope.authSignalRevision, gate.authSignals.value,
        gate.refreshEntryRevision, _epoch);
    if (!_current(candidate)) return null;
    _intent = candidate;
    return marker;
    } catch (_) { return null; }
  }

  bool _current(_Intent intent) {
    try {
      return identical(_source, intent.scope) && identical(_gate, intent.gate) &&
          _epoch == intent.epoch && intent.scope.isCurrent(intent.owner) &&
          intent.scope.authSignalRevision == intent.scopeRevision &&
          intent.gate.authSignals.value == intent.authRevision &&
          intent.gate.refreshEntryRevision == intent.refreshRevision &&
          intent.gate.activeAuthOperations == 0 && intent.gate.refreshEntrants == 0 &&
          identical(intent.getSession(), intent.session);
    } catch (_) { return false; }
  }

  void closed(Object? marker) {
    final intent = _intent;
    if (intent != null && identical(intent.marker, marker) && !intent.suspended) cancel();
  }

  void suspendForReconnect() {
    final intent = _intent;
    if (intent == null) return;
    if (!intent.route.isCurrent || !_current(intent)) { cancel(); return; }
    intent.suspended = true;
    intent.removable.addAll(_routes);
  }

  /// Called only by the splash after a successful online admission.
  void allowOnlineHome() {
    final intent = _intent;
    if (intent == null) return;
    if (!intent.suspended || !intent.sawSplash || !_current(intent)) { cancel(); return; }
    intent.allowHome = true;
    final splash = intent.splashRoute;
    if (splash != null) intent.removable.add(splash);
  }

  void cancel() { _epoch++; _intent = null; }

  ReconnectChatClaim? claim() {
    final intent = _intent;
    if (intent == null) return null;
    if (!intent.suspended || !_current(intent)) { cancel(); return null; }
    if (!intent.sawHome) return null;
    _intent = null;
    return ReconnectChatClaim._(intent, navigationRevision);
  }
}

class _Intent {
  _Intent(this.marker, this.scope, this.owner, this.route, this.chatId,
      this.targetId, this.dm, this.gate, this.getSession, this.session,
      this.scopeRevision, this.authRevision, this.refreshRevision, this.epoch);
  final Object marker;
  final AuthSessionScope scope;
  final AuthOperationScope owner;
  final Route<dynamic> route;
  final String chatId, targetId;
  final bool dm;
  final RefreshAdmissionClient gate;
  final Session? Function() getSession;
  final Session session;
  final int scopeRevision, authRevision, refreshRevision, epoch;
  bool suspended = false;
  bool sawSplash = false, allowHome = false, sawHome = false;
  Route<dynamic>? splashRoute;
  final Set<Route<dynamic>> removable = {};
}

class ReconnectChatClaim {
  ReconnectChatClaim._(this._intent, this._navigationRevision);
  final _Intent _intent;
  final int _navigationRevision;
  String get chatId => _intent.chatId;
  String get targetId => _intent.targetId;
  bool get dm => _intent.dm;
  AuthSessionScope get scope => _intent.scope;
  bool get current => ReconnectChatIntent.instance._current(_intent) &&
      ReconnectChatIntent.instance.navigationRevision == _navigationRevision;
}

class ReconnectNavigationObserver extends NavigatorObserver {
  void _changed() => ReconnectChatIntent.instance.navigationRevision++;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _changed();
    ReconnectChatIntent.instance._routes.add(route);
    final intent = ReconnectChatIntent.instance._intent;
    if (intent != null) {
      if (!intent.suspended) {
        if (!identical(route, intent.route)) ReconnectChatIntent.instance.cancel();
      } else if (!intent.sawSplash && route.settings.name == '/splash') {
        intent.sawSplash = true;
        intent.splashRoute = route;
      } else if (intent.sawSplash && intent.allowHome && !intent.sawHome && route.settings.name == '/home') {
        intent.sawHome = true;
      } else {
        ReconnectChatIntent.instance.cancel();
      }
    }
  }
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _changed();
    ReconnectChatIntent.instance._routes.remove(route);
    if (ReconnectChatIntent.instance._intent != null) {
      ReconnectChatIntent.instance.cancel();
    }
  }
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _changed();
    ReconnectChatIntent.instance._routes.remove(route);
    final intent = ReconnectChatIntent.instance._intent;
    if (intent != null && (!intent.suspended || !intent.removable.remove(route))) {
      ReconnectChatIntent.instance.cancel();
    }
  }
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _changed();
    if (oldRoute != null) ReconnectChatIntent.instance._routes.remove(oldRoute);
    if (newRoute != null) ReconnectChatIntent.instance._routes.add(newRoute);
    if (ReconnectChatIntent.instance._intent != null) {
      ReconnectChatIntent.instance.cancel();
    }
  }
}
