import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_session_scope.dart';
import 'offline_policy_grant.dart';

abstract class OfflineGrantStorage {
  Future<String?> read(String key);
  Future<bool> write(String key, String value);
  Future<bool> remove(String key);
}

class PreferencesOfflineGrantStorage implements OfflineGrantStorage {
  PreferencesOfflineGrantStorage(
      {Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;
  final Future<SharedPreferences> Function() _preferences;
  @override
  Future<String?> read(String key) async =>
      (await _preferences()).getString(key);
  @override
  Future<bool> write(String key, String value) async =>
      (await _preferences()).setString(key, value);
  @override
  Future<bool> remove(String key) async => (await _preferences()).remove(key);
}

class OfflineGrantStorageException implements Exception {
  const OfflineGrantStorageException();
  @override
  String toString() => 'OfflineGrantStorageException';
}

/// Shared for the full host lifetime and bound to a single storage backend.
class OfflineGrantCoordinator {
  OfflineGrantCoordinator(this._storage);
  final OfflineGrantStorage _storage;
  final Map<String, int> _revisions = {};
  final Map<String, int> _liveRevisions = {};
  final Map<String, Future<void>> _queue = {};
  final Set<String> _quarantined = {};
}

/// Opaque fence captured *before* the live policy request begins.
class OfflineGrantAttempt {
  OfflineGrantAttempt._(this._issuer, this._owner, this._binding, this._key,
      this._revision, this._liveRevision);
  final Object _issuer;
  final AuthOperationScope _owner;
  final OfflineSessionBinding _binding;
  final String _key;
  final int _revision;
  final int _liveRevision;
  bool _used = false;
}

/// One store per app scope. It does not verify JWT signatures, check live
/// policy or grant capabilities. A caller must verify those independently.
class OfflinePolicyGrantStore {
  OfflinePolicyGrantStore(
      {required AuthSessionScope session,
      required OfflineSessionBinding? Function() currentBinding,
      OfflineGrantStorage? storage,
      OfflineGrantCoordinator? coordinator})
      : assert((storage == null) != (coordinator == null)),
        _coordinator = coordinator ?? OfflineGrantCoordinator(storage!),
        _session = session,
        _currentBinding = currentBinding;
  final AuthSessionScope _session;
  final OfflineSessionBinding? Function() _currentBinding;
  final OfflineGrantCoordinator _coordinator;
  final Object _issuer = Object();
  bool _disposed = false;

  String _key(OfflineSessionBinding binding) =>
      'offline_policy_v1_${sha256.convert(utf8.encode(jsonEncode([
            binding.issuer,
            binding.userId,
            binding.sessionId
          ])))}';
  bool _sameBinding(OfflineSessionBinding? a, OfflineSessionBinding b) =>
      a != null &&
      a.issuer == b.issuer &&
      a.userId == b.userId &&
      a.sessionId == b.sessionId;
  bool _valid(OfflineGrantAttempt attempt, {bool live = false}) =>
      !_disposed &&
      identical(attempt._issuer, _issuer) &&
      _session.isCurrent(attempt._owner) &&
      attempt._owner.userId == attempt._binding.userId &&
      _sameBinding(_currentBinding(), attempt._binding) &&
      (_coordinator._revisions[attempt._key] ?? 0) == attempt._revision &&
      (!live ||
          (_coordinator._liveRevisions[attempt._key] ?? 0) ==
              attempt._liveRevision) &&
      !_coordinator._quarantined.contains(attempt._key);

  OfflineGrantAttempt? beginLiveCheck(
      AuthOperationScope owner, OfflineSessionBinding binding) {
    final captured = _capture(owner, binding);
    if (captured == null) return null;
    final next = (_coordinator._liveRevisions[captured._key] ?? 0) + 1;
    _coordinator._liveRevisions[captured._key] = next;
    return OfflineGrantAttempt._(
        _issuer, owner, binding, captured._key, captured._revision, next);
  }

  OfflineGrantAttempt? _capture(
      AuthOperationScope owner, OfflineSessionBinding binding) {
    final key = _key(binding);
    if (_disposed ||
        !_session.isCurrent(owner) ||
        owner.userId != binding.userId ||
        !_sameBinding(_currentBinding(), binding) ||
        _coordinator._quarantined.contains(key)) return null;
    return OfflineGrantAttempt._(
        _issuer,
        owner,
        binding,
        key,
        _coordinator._revisions[key] ?? 0,
        _coordinator._liveRevisions[key] ?? 0);
  }

  Future<T> _serial<T>(String key, Future<T> Function() task) {
    final result = Completer<T>();
    final previous = _coordinator._queue[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) async {
      try {
        result.complete(await task());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).whenComplete(() {
      if (identical(_coordinator._queue[key], next))
        _coordinator._queue.remove(key);
    });
    _coordinator._queue[key] = next;
    return result.future;
  }

  Future<bool> saveAfterLiveCheck(
      OfflineGrantAttempt attempt, OfflinePolicyGrant grant) {
    if (!_valid(attempt, live: true) ||
        attempt._used ||
        grant.issuer != attempt._binding.issuer ||
        grant.userId != attempt._binding.userId ||
        grant.sessionId != attempt._binding.sessionId ||
        OfflinePolicyGrant.fromJson(grant.toJson()) == null)
      return Future.value(false);
    attempt._used = true;
    final key = attempt._key;
    return _serial(key, () async {
      if (!_valid(attempt, live: true)) return false;
      try {
        if (!await _coordinator._storage
            .write(key, jsonEncode(grant.toJson()))) {
          throw const OfflineGrantStorageException();
        }
        if (!_valid(attempt, live: true)) {
          _coordinator._quarantined.add(key);
          if (!await _coordinator._storage.remove(key))
            throw const OfflineGrantStorageException();
          if ((_coordinator._revisions[key] ?? 0) == attempt._revision) {
            _coordinator._quarantined.remove(key);
          }
          return false;
        }
        return true;
      } catch (_) {
        _coordinator._quarantined.add(key);
        throw const OfflineGrantStorageException();
      }
    });
  }

  Future<OfflinePolicyGrant?> read(
      AuthOperationScope owner, OfflineSessionBinding binding) {
    final attempt = _capture(owner, binding);
    if (attempt == null) return Future.value(null);
    return _serial(attempt._key, () async {
      if (!_valid(attempt)) return null;
      try {
        final raw = await _coordinator._storage.read(attempt._key);
        if (!_valid(attempt) || raw == null) return null;
        final grant = OfflinePolicyGrant.fromJson(jsonDecode(raw));
        if (grant == null ||
            grant.issuer != binding.issuer ||
            grant.userId != binding.userId ||
            grant.sessionId != binding.sessionId) return null;
        return grant;
      } on FormatException {
        return null;
      } catch (_) {
        _coordinator._quarantined.add(attempt._key);
        throw const OfflineGrantStorageException();
      }
    });
  }

  /// Revokes synchronously in this process; durable removal completes later.
  Future<void> blockAndRevoke(OfflineSessionBinding binding) {
    if (_disposed)
      return Future.error(StateError('Offline grant store disposed'));
    final key = _key(binding);
    final revision = (_coordinator._revisions[key] ?? 0) + 1;
    _coordinator._revisions[key] = revision;
    _coordinator._quarantined.add(key);
    return _serial(key, () async {
      try {
        if (!await _coordinator._storage.remove(key))
          throw const OfflineGrantStorageException();
        if (_coordinator._revisions[key] == revision)
          _coordinator._quarantined.remove(key);
      } catch (_) {
        _coordinator._quarantined.add(key);
        throw const OfflineGrantStorageException();
      }
    });
  }

  void dispose() {
    _disposed = true;
  }
}
