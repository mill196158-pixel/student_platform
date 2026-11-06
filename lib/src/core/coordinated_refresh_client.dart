import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:student_platform/src/config/supabase_config.dart';

import 'sqlite_policy_grant_store.dart';
import 'auth_session_scope.dart';
import 'offline_policy_grant.dart';
import 'refresh_security_fence.dart';
import 'transport_failure_platform_stub.dart'
    if (dart.library.io) 'transport_failure_platform_io.dart' as transport;

/// Tracks only settled underlying sends. It does not interpret SDK exceptions.
class RefreshTransportMonitor {
  int _active = 0, _sent = 0;
  bool _onlySocketFailures = true;
  SqliteLiveGrantAttempt? _latest;
  bool get eligible =>
      _sent > 0 && _active == 0 && _onlySocketFailures && _latest != null;
  SqliteLiveGrantAttempt? get latest => eligible ? _latest : null;
  void _start(SqliteLiveGrantAttempt attempt) {
    _active++;
    _sent++;
    _latest = attempt;
  }

  void _finish(Object? error) {
    if (error == null || !transport.isSocketFailure(error))
      _onlySocketFailures = false;
    _active--;
  }
}

class RefreshTransportSuppressed extends http.ClientException {
  RefreshTransportSuppressed() : super('Refresh transport suspended');
}

/// Fences the exact auth refresh request before transport. The caller must own
/// one live SQLite store/coordinator for the whole app and initialize it before
/// enabling SDK auto-refresh. This client does not grant cached access.
class CoordinatedRefreshClient extends http.BaseClient {
  CoordinatedRefreshClient(this._inner, this._store,
      {required String? Function() currentRefreshToken,
      RefreshSecurityFence? securityFence,
      this.monitor})
      : _securityFence = securityFence ?? RefreshSecurityFence(),
        _currentRefreshToken = currentRefreshToken,
        _backend = Uri.parse(SupabaseConfig.url);

  @visibleForTesting
  CoordinatedRefreshClient.forTesting(this._inner, this._store, this._backend,
      {required String? Function() currentRefreshToken,
      RefreshSecurityFence? securityFence,
      this.monitor})
      : _securityFence = securityFence ?? RefreshSecurityFence(),
        _currentRefreshToken = currentRefreshToken;

  final http.Client _inner;
  final RefreshTransportMonitor? monitor;
  final RefreshSecurityFence _securityFence;
  final SqlitePolicyGrantStore _store;
  final Uri _backend;
  final String? Function() _currentRefreshToken;

  bool _isRefresh(http.BaseRequest request) {
    final uri = request.url;
    return _backend.scheme == 'https' &&
        _backend.userInfo.isEmpty &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.host == _backend.host &&
        uri.port == _backend.port &&
        uri.path == '/auth/v1/token' &&
        uri.queryParameters['grant_type'] == 'refresh_token' &&
        request.method == 'POST';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_isRefresh(request)) return _inner.send(request);
    final AuthOperationScope? owner;
    final OfflineSessionBinding? binding;
    final String? token;
    try {
      owner = _store.scope.capture();
      binding = _store.currentBinding();
      token = _currentRefreshToken();
    } catch (_) {
      _securityFence.reject();
    }
    final issuer = '${_backend.origin}/auth/v1';
    Object? body;
    try {
      if (request is http.Request) body = jsonDecode(request.body);
    } catch (_) {}
    if (owner == null ||
        binding == null ||
        binding.issuer != issuer ||
        token == null ||
        token.isEmpty ||
        body is! Map ||
        body['refresh_token'] != token) {
      _securityFence.reject();
    }
    final SqliteLiveGrantAttempt? attempt;
    try {
      attempt = await _store.beginLiveCheck(owner, binding);
    } catch (_) {
      _securityFence.reject();
    }
    if (attempt == null) {
      _securityFence.reject();
    }
    try {
      if (!_store.scope.isCurrent(owner) || _currentRefreshToken() != token) {
        _securityFence.reject();
      }
    } on RefreshSecurityFenceException {
      rethrow;
    } catch (_) {
      _securityFence.reject();
    }
    // Never forward a refresh token to a redirect target.
    request.followRedirects = false;
    final http.StreamedResponse response;
    monitor?._start(attempt);
    try {
      response = await _inner.send(request);
      monitor?._finish(null);
    } catch (error) {
      monitor?._finish(error);
      rethrow;
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      final bool revoked;
      try {
        revoked = await _store.revokeAfterLiveCheck(attempt);
      } catch (_) {
        _securityFence.reject();
      }
      if (!revoked) {
        // Do not expose an old denial to a newer session or claim persistence.
        try {
          await response.stream.listen((_) {}).cancel();
        } catch (_) {
          // A cancellation failure cannot turn a security failure into outage.
        }
        _securityFence.reject();
      }
    }
    // Success or transport failure leaves the pending marker fail-closed until
    // a separate verified policy check supplies a new grant.
    return response;
  }

  @override
  void close() => _inner.close();
}

/// Instantiated before Supabase.initialize: SDK recovery may start before that
/// future returns. Refresh requests wait for exactly one configured coordinator.
/// Non-refresh traffic does not wait; this object never logs request bodies.
class RefreshAdmissionClient extends http.BaseClient {
  RefreshAdmissionClient(this._inner,
      {Uri? backend, RefreshSecurityFence? securityFence})
      : _securityFence = securityFence ?? RefreshSecurityFence(),
        _backend = backend ?? Uri.parse(SupabaseConfig.url);
  final http.Client _inner;
  final Uri _backend;
  final RefreshSecurityFence _securityFence;
  final Completer<http.Client?> _admission = Completer<http.Client?>();
  bool _closed = false;
  bool _suspended = false;
  int _activeAuth = 0;
  int _nonRefreshAuthRevision = 0;
  int _suppressedAuthRevision = 0;
  final ValueNotifier<int> authSignals = ValueNotifier<int>(0);
  /// Changes on every non-refresh auth dispatch, even if it later fails.
  int get nonRefreshAuthRevision => _nonRefreshAuthRevision;
  int get suppressedAuthRevision => _suppressedAuthRevision;
  int get activeAuthOperations => _activeAuth;
  final List<Completer<void>> _drainers = [];

  /// Blocks new auth sends synchronously, then waits for dispatched auth sends.
  /// This does not stop WebSockets or other HTTP clients.
  Future<void> suspendAndDrain() {
    _suspended = true;
    if (_activeAuth == 0) return Future.value();
    final done = Completer<void>();
    _drainers.add(done);
    return done.future;
  }

  /// Called only after the same owner receives a verified online policy result.
  void resume() {
    if (!_closed) _suspended = false;
  }

  void bind(http.Client guardedClient) {
    if (_closed || _admission.isCompleted) {
      throw StateError('Refresh admission already resolved');
    }
    _admission.complete(guardedClient);
  }

  void block() {
    if (!_admission.isCompleted) _admission.complete(null);
  }

  bool _refresh(http.BaseRequest request) {
    final uri = request.url;
    return _backend.scheme == 'https' &&
        _backend.userInfo.isEmpty &&
        uri.scheme == 'https' &&
        uri.userInfo.isEmpty &&
        uri.host == _backend.host &&
        uri.port == _backend.port &&
        uri.path == '/auth/v1/token' &&
        uri.queryParameters['grant_type'] == 'refresh_token' &&
        request.method == 'POST';
  }

  bool _auth(http.BaseRequest request) {
    final uri = request.url;
    return _backend.scheme == 'https' && _backend.userInfo.isEmpty &&
        uri.scheme == 'https' && uri.userInfo.isEmpty &&
        uri.host == _backend.host && uri.port == _backend.port &&
        (uri.path == '/auth/v1' || uri.path.startsWith('/auth/v1/'));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) _securityFence.reject();
    if (!_auth(request)) return _inner.send(request);
    if (_suspended) {
      _suppressedAuthRevision++;
      authSignals.value++;
      throw RefreshTransportSuppressed();
    }
    if (!_refresh(request)) {
      _nonRefreshAuthRevision++;
      authSignals.value++;
      _activeAuth++;
      try {
        return await _inner.send(request);
      } finally {
        _authFinished();
      }
    }
    final guarded = await _admission.future;
    if (_closed || guarded == null) _securityFence.reject();
    if (_suspended) {
      _suppressedAuthRevision++;
      authSignals.value++;
      throw RefreshTransportSuppressed();
    }
    authSignals.value++;
    _activeAuth++;
    try {
      return await guarded.send(request);
    } finally {
      _authFinished();
    }
  }

  void _authFinished() {
    _activeAuth--;
    if (_activeAuth == 0) {
      for (final done in _drainers) {
        done.complete();
      }
      _drainers.clear();
    }
  }

  @override
  void close() {
    _closed = true;
    authSignals.value++;
    block();
    _inner.close();
  }
}
