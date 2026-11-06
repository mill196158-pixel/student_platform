import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';

/// Local snapshots for existing home sections. The caller must establish
/// authorization before reading, and may only write a successful response.
class HomeSnapshotCache {
  HomeSnapshotCache({
    required String? Function() currentUserId,
    required int Function() sessionGeneration,
    required Object? Function() sessionIdentity,
    this.project,
    this.authScope,
    Future<SharedPreferences> Function()? preferences,
  })  : _currentUserId = currentUserId,
        _sessionGeneration = sessionGeneration,
        _sessionIdentity = sessionIdentity,
        _preferences = preferences ?? SharedPreferences.getInstance;

  final String? Function() _currentUserId;
  final int Function() _sessionGeneration;
  final Object? Function() _sessionIdentity;
  final String? project;
  final AuthSessionScope? authScope;
  final Future<SharedPreferences> Function() _preferences;
  final Object _scopeIssuer = Object();
  static final Map<String, int> _writeVersions = <String, int>{};
  static final Map<String, Future<void>> _pendingWrites =
      <String, Future<void>>{};

  String _key(String uid, HomeSnapshotSection section) => project == null
      ? 'home_snapshot_v1_${section.name}_$uid'
      : 'home_snapshot_v2_${section.name}_${sha256.convert(utf8.encode(jsonEncode([
              project,
              uid
            ])))}';

  /// Capture before the network request, not after its response arrives.
  HomeSnapshotScope? captureScope(String userId) {
    final uid = userId.trim();
    final generation = _sessionGeneration();
    final identity = _sessionIdentity();
    if (!_isCurrent(uid, generation, identity)) return null;
    return HomeSnapshotScope._(_scopeIssuer, uid, generation, identity!);
  }

  bool isCurrent(HomeSnapshotScope scope) =>
      identical(scope._issuer, _scopeIssuer) &&
      _isCurrent(scope._uid, scope._generation, scope._identity);

  Future<HomeSectionSnapshot?> read(
      String userId, HomeSnapshotSection section) async {
    final uid = userId.trim();
    final generation = _sessionGeneration();
    final identity = _sessionIdentity();
    if (!_isCurrent(uid, generation, identity)) return null;
    final prefs = await _preferences();
    if (!_isCurrent(uid, generation, identity)) return null;
    final raw = prefs.getString(_key(uid, section));
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value['version'] != 1 ||
          value['owner'] != uid ||
          value['items'] is! List ||
          value['savedAt'] is! String) return null;
      final savedAt = DateTime.tryParse(value['savedAt'] as String);
      if (savedAt == null) return null;
      final items = <Map<String, dynamic>>[];
      for (final item in value['items'] as List) {
        if (item is! Map || item.keys.any((key) => key is! String)) return null;
        items.add(Map<String, dynamic>.from(item));
      }
      return HomeSectionSnapshot(
        savedAt: savedAt,
        date: value['date'] is String ? value['date'] as String : null,
        items: items,
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> write({
    required HomeSnapshotScope scope,
    required HomeSnapshotSection section,
    required List<Map<String, dynamic>> items,
    String? date,
    required DateTime savedAt,
  }) async {
    if (!identical(scope._issuer, _scopeIssuer)) return false;
    final uid = scope._uid;
    final generation = scope._generation;
    final identity = scope._identity;
    if (!_isCurrent(uid, generation, identity)) return false;
    final key = _key(uid, section);
    final version = (_writeVersions[key] ?? 0) + 1;
    _writeVersions[key] = version;
    final raw = jsonEncode({
      'version': 1,
      'owner': uid,
      'date': date,
      'savedAt': savedAt.toUtc().toIso8601String(),
      'items': items,
    });
    final previous = _pendingWrites[key];
    final finished = Completer<void>();
    _pendingWrites[key] = finished.future;
    try {
      if (previous != null) await previous;
      if (!_isCurrent(uid, generation, identity) ||
          _writeVersions[key] != version) {
        return false;
      }
      final prefs = await _preferences();
      if (!_isCurrent(uid, generation, identity) ||
          _writeVersions[key] != version) {
        return false;
      }
      final saved = await prefs.setString(key, raw);
      return saved &&
          _isCurrent(uid, generation, identity) &&
          _writeVersions[key] == version;
    } finally {
      finished.complete();
      if (identical(_pendingWrites[key], finished.future))
        _pendingWrites.remove(key);
    }
  }

  bool _isCurrent(String uid, int generation, Object? identity) =>
      uid.isNotEmpty &&
      identity != null &&
      _currentUserId() == uid &&
      _sessionGeneration() == generation &&
      _sessionIdentity() == identity;
}

class HomeSnapshotScope {
  const HomeSnapshotScope._(
      this._issuer, this._uid, this._generation, this._identity);
  final Object _issuer;
  final String _uid;
  final int _generation;
  final Object _identity;
}

enum HomeSnapshotSection { schedule, assignments, profile }

class HomeSectionSnapshot {
  const HomeSectionSnapshot(
      {required this.savedAt, required this.items, this.date});
  final DateTime savedAt;
  final String? date;
  final List<Map<String, dynamic>> items;
}
