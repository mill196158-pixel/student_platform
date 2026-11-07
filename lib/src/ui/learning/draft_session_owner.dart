import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

@visibleForTesting
String normalizeDraftProject(String value) => value.replaceFirst(RegExp(r'/+$'), '');

/// A screen captures this once; it cannot follow a different signed-in user.
class DraftSessionOwner {
  DraftSessionOwner._(this._scope, this._generation, this._client,
      this.project, this.userId, this._sessionId);
  final AuthSessionScope _scope;
  final int _generation;
  final SupabaseClient _client;
  final String project;
  final String userId;
  final String _sessionId;
  String get sessionId => _sessionId;

  Listenable get changes => _scope;
  bool get sameGeneration => _scope.generation == _generation && !_scope.logoutFenced;

  static DraftSessionOwner? capture(AuthSessionScope? scope) {
    if (scope == null) return null;
    try {
      final client = Supabase.instance.client;
      final owner = scope.capture();
      if (owner == null || !scope.matchesSession(owner, client.auth.currentSession)) return null;
      final project = normalizeDraftProject(SupabaseConfig.url);
      final binding = scope.bindingFor(owner, '$project/auth/v1');
      if (binding == null) return null;
      return DraftSessionOwner._(scope, scope.generation, client, project,
          binding.userId, binding.sessionId);
    } catch (_) {
      return null;
    }
  }

  bool get canRead => _matches();
  bool get canSave => _matches();

  /// Only an isolated, append-only recovery entry may be attempted while the
  /// SDK temporarily has no session. It cannot replace the canonical draft.
  bool get canJournal {
    try {
      if (!sameGeneration || !identical(_client, Supabase.instance.client)) return false;
      final session = _client.auth.currentSession;
      if (session == null) return true;
      final binding = OfflineSessionBinding.fromSession(session, '$project/auth/v1');
      return binding != null && binding.userId == userId &&
          binding.sessionId == _sessionId && _scope.capture() == null;
    } catch (_) { return false; }
  }

  bool _matches() {
    try {
      if (_scope.generation != _generation || _scope.logoutFenced ||
          !identical(_client, Supabase.instance.client)) return false;
      final session = _client.auth.currentSession;
      if (session == null) return false;
      final operation = _scope.capture();
      if (operation == null || operation.userId != userId ||
          !_scope.matchesSession(operation, session)) return false;
      final binding = OfflineSessionBinding.fromSession(session, '$project/auth/v1');
      return binding != null && binding.userId == userId &&
          binding.sessionId == _sessionId;
    } catch (_) {
      return false;
    }
  }
}

/// Captures the route's owner synchronously, before an asynchronous startup or
/// first-frame callback can accidentally observe another signed-in account.
class DraftSessionSeed {
  DraftSessionSeed._(this._scope, this._generation, this._client,
      this._project, this._userId, this._sessionId);
  final AuthSessionScope _scope;
  final int _generation;
  final SupabaseClient _client;
  final String _project, _userId, _sessionId;

  static DraftSessionSeed? capture(AuthSessionScope? scope) {
    if (scope == null || scope.logoutFenced) return null;
    try {
      final client = Supabase.instance.client;
      final session = client.auth.currentSession;
      if (session == null) return null;
      final project = normalizeDraftProject(SupabaseConfig.url);
      final binding = OfflineSessionBinding.fromSession(session, '$project/auth/v1');
      if (binding == null) return null;
      return DraftSessionSeed._(scope, scope.generation, client, project,
          binding.userId, binding.sessionId);
    } catch (_) { return null; }
  }

  Future<void> get ready => _scope.ready;
  bool get sameEpoch => _scope.generation == _generation && !_scope.logoutFenced;

  DraftSessionOwner? confirm() {
    try {
      if (_scope.generation != _generation || _scope.logoutFenced ||
          !identical(_client, Supabase.instance.client)) return null;
      final owner = DraftSessionOwner.capture(_scope);
      if (owner == null || owner.project != _project || owner.userId != _userId ||
          owner.sessionId != _sessionId || !owner.canRead) return null;
      return owner;
    } catch (_) { return null; }
  }
}
