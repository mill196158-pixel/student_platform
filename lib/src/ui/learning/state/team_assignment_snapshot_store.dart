import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../../home/home_snapshot_codec.dart';
import '../models/assignment.dart';
import 'team_cache_owner.dart';

abstract class TeamSnapshotStorage {
  Future<Set<String>> keys();
  Future<String?> read(String key);
  Future<bool> write(String key, String value);
  Future<bool> remove(String key);
}

class TeamSnapshotStorageFailure implements Exception {
  const TeamSnapshotStorageFailure();
}

class OwnerClearResult {
  const OwnerClearResult(
      {required this.scanSucceeded,
      required this.removed,
      required this.failed,
      required this.unattributed});
  final bool scanSucceeded;
  final int removed;
  final int failed;
  final int unattributed;
  bool get safeToUnblock => scanSucceeded && failed == 0;
  bool get complete => scanSucceeded && failed == 0 && unattributed == 0;
}

class TeamSnapshotCoordinator {
  TeamSnapshotCoordinator(this.storage);
  final TeamSnapshotStorage storage;
  final _revisions = <String, int>{};
  final _queues = <String, Future<void>>{};
  final _quarantined = <String>{};
  final _ownerEpochs = <String, int>{};
  final _blockedOwners = <String>{};
  final _clearQueues = <String, Future<void>>{};
  final _knownKeys = <String, (String, String, String)>{};

  static String _ownerKey(String project, String uid) =>
      jsonEncode([project, uid]);
  static String _snapshotKey(String project, String uid, String teamId) =>
      'team_assign_v2_${sha256.convert(utf8.encode(jsonEncode([
            project,
            uid,
            teamId
          ])))}';

  /// Synchronously fences this owner before any storage operation starts.
  /// A caller may time out waiting, but the queued clear continues.
  Future<OwnerClearResult> beginClear(String project, String uid) {
    if (project.trim().isEmpty || uid.trim().isEmpty)
      throw const FormatException('Missing owner');
    final ownerKey = _ownerKey(project, uid);
    final epoch = (_ownerEpochs[ownerKey] ?? 0) + 1;
    _ownerEpochs[ownerKey] = epoch;
    _blockedOwners.add(ownerKey);
    final result = Completer<OwnerClearResult>();
    final previous = _clearQueues[ownerKey] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) async {
      var outcome = const OwnerClearResult(
          scanSucceeded: false, removed: 0, failed: 0, unattributed: 0);
      try {
        outcome = await _clearOwner(project, uid);
      } catch (_) {}
      if (outcome.safeToUnblock && _ownerEpochs[ownerKey] == epoch)
        _blockedOwners.remove(ownerKey);
      result.complete(outcome);
    }).whenComplete(() {
      if (identical(_clearQueues[ownerKey], next))
        _clearQueues.remove(ownerKey);
    });
    _clearQueues[ownerKey] = next;
    return result.future;
  }

  Future<OwnerClearResult> _clearOwner(String project, String uid) async {
    var scanSucceeded = true, removed = 0, failed = 0, unattributed = 0;
    final candidates = <String, (String, String, String)>{};
    for (final entry in _knownKeys.entries) {
      if (entry.value.$1 == project && entry.value.$2 == uid)
        candidates[entry.key] = entry.value;
    }
    Set<String> keys;
    try {
      keys = await storage.keys();
    } catch (_) {
      scanSucceeded = false;
      keys = {};
    }
    for (final key in keys.where((key) => key.startsWith('team_assign_v2_'))) {
      String? raw;
      try {
        raw = await storage.read(key);
      } catch (_) {
        scanSucceeded = false;
        continue;
      }
      if (raw == null) continue;
      try {
        final value = jsonDecode(raw);
        if (value is! Map ||
            value['schema'] != 2 ||
            value['project'] is! String ||
            value['uid'] is! String ||
            value['teamId'] is! String ||
            (value['project'] as String).isEmpty ||
            (value['uid'] as String).isEmpty ||
            (value['teamId'] as String).isEmpty ||
            _snapshotKey(value['project'] as String, value['uid'] as String,
                    value['teamId'] as String) !=
                key) {
          if (!candidates.containsKey(key)) unattributed++;
          continue;
        }
        final descriptor = (
          value['project'] as String,
          value['uid'] as String,
          value['teamId'] as String
        );
        if (descriptor.$1 == project && descriptor.$2 == uid) {
          candidates[key] = descriptor;
          _knownKeys[key] = descriptor;
        }
      } catch (_) {
        if (!candidates.containsKey(key)) unattributed++;
      }
    }
    for (final entry in candidates.entries) {
      final ok = await serial(entry.key, () async {
        try {
          final raw = await storage.read(entry.key);
          if (raw != null) {
            Object? value;
            try {
              value = jsonDecode(raw);
            } catch (_) {
              // An in-process registered key has a known owner even if its
              // content was damaged by an earlier failed write.
              if (_knownKeys[entry.key] != entry.value) return false;
            }
            if (_knownKeys[entry.key] != entry.value) return false;
            if (value is Map &&
                value['project'] is String &&
                value['uid'] is String &&
                value['teamId'] is String &&
                _snapshotKey(value['project'] as String, value['uid'] as String,
                        value['teamId'] as String) ==
                    entry.key &&
                (value['project'] != entry.value.$1 ||
                    value['uid'] != entry.value.$2 ||
                    value['teamId'] != entry.value.$3)) return false;
          }
          // Retry removal even if the in-memory preference was already erased
          // by a previous unsuccessful platform call.
          if (!await storage.remove(entry.key)) {
            _quarantined.add(entry.key);
            return false;
          }
          _quarantined.remove(entry.key);
          _knownKeys.remove(entry.key);
          return true;
        } catch (_) {
          _quarantined.add(entry.key);
          return false;
        }
      });
      if (ok) {
        removed++;
      } else {
        failed++;
      }
    }
    return OwnerClearResult(
        scanSucceeded: scanSucceeded,
        removed: removed,
        failed: failed,
        unattributed: unattributed);
  }

  Future<T> serial<T>(String key, Future<T> Function() work) {
    final result = Completer<T>();
    final previous = _queues[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) async {
      try {
        result.complete(await work());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    }).whenComplete(() {
      if (identical(_queues[key], next)) _queues.remove(key);
    });
    _queues[key] = next;
    return result.future;
  }
}

enum TeamSnapshotStatus { found, missing, corrupt }

class TeamAssignmentSnapshot {
  const TeamAssignmentSnapshot(this.status, this.assignments, this.savedAt);
  final TeamSnapshotStatus status;
  final List<Assignment> assignments;
  final DateTime? savedAt;
}

class TeamSnapshotAttempt {
  TeamSnapshotAttempt._(
      this._issuer, this._ticket, this._revision, this._ownerEpoch);
  final Object _issuer;
  final TeamCacheTicket _ticket;
  final int _revision;
  final int _ownerEpoch;
  bool _used = false;
}

/// Standalone cache storage; callers must establish authorization separately.
class TeamAssignmentSnapshotStore {
  TeamAssignmentSnapshotStore(
      {required this.owner, required this.project, required this.coordinator});
  final TeamCacheOwner owner;
  final String project;
  final TeamSnapshotCoordinator coordinator;
  final Object _issuer = Object();
  bool _disposed = false;

  String get _key =>
      TeamSnapshotCoordinator._snapshotKey(project, owner.userId, owner.teamId);
  String get _ownerKey =>
      TeamSnapshotCoordinator._ownerKey(project, owner.userId);
  int get _ownerEpoch => coordinator._ownerEpochs[_ownerKey] ?? 0;
  bool _valid(TeamCacheTicket ticket, int epoch) =>
      !_disposed &&
      owner.isCurrent(ticket) &&
      !coordinator._blockedOwners.contains(_ownerKey) &&
      _ownerEpoch == epoch;
  void _register() =>
      coordinator._knownKeys[_key] = (project, owner.userId, owner.teamId);

  /// Capture before starting the corresponding network load.
  TeamSnapshotAttempt? beginLoad() {
    final ticket = owner.capture();
    if (ticket == null ||
        _disposed ||
        project.trim().isEmpty ||
        coordinator._blockedOwners.contains(_ownerKey) ||
        coordinator._quarantined.contains(_key)) return null;
    _register();
    final revision = (coordinator._revisions[_key] ?? 0) + 1;
    coordinator._revisions[_key] = revision;
    return TeamSnapshotAttempt._(_issuer, ticket, revision, _ownerEpoch);
  }

  Future<TeamAssignmentSnapshot> read(TeamCacheTicket ticket) {
    final epoch = _ownerEpoch;
    _register();
    return coordinator.serial(_key, () async {
      _check(ticket, epoch);
      final raw = await _read();
      _check(ticket, epoch);
      if (raw == null)
        return const TeamAssignmentSnapshot(
            TeamSnapshotStatus.missing, [], null);
      try {
        final value = jsonDecode(raw);
        if (value is! Map ||
            value['schema'] != 2 ||
            value['project'] != project ||
            value['uid'] != owner.userId ||
            value['teamId'] != owner.teamId ||
            value['savedAt'] is! String ||
            value['items'] is! List) {
          return const TeamAssignmentSnapshot(
              TeamSnapshotStatus.corrupt, [], null);
        }
        final savedAt = DateTime.tryParse(value['savedAt'] as String);
        if (savedAt == null ||
            !savedAt.isUtc ||
            savedAt.toIso8601String() != value['savedAt']) {
          return const TeamAssignmentSnapshot(
              TeamSnapshotStatus.corrupt, [], null);
        }
        final items = <Assignment>[];
        for (final item in value['items'] as List) {
          if (item is! Map || item.keys.any((key) => key is! String)) {
            return const TeamAssignmentSnapshot(
                TeamSnapshotStatus.corrupt, [], null);
          }
          final parsed = HomeSnapshotCodec.assignmentFromMap(
              {'teamName': '', 'assignment': item});
          if (parsed == null)
            return const TeamAssignmentSnapshot(
                TeamSnapshotStatus.corrupt, [], null);
          final assignment = parsed.assignment;
          items.add(assignment.copyWith(
              attachments: List.unmodifiable(assignment.attachments
                  .map((a) => Map<String, String>.unmodifiable(a)))));
        }
        return TeamAssignmentSnapshot(
            TeamSnapshotStatus.found, List.unmodifiable(items), savedAt);
      } catch (_) {
        return const TeamAssignmentSnapshot(
            TeamSnapshotStatus.corrupt, [], null);
      }
    });
  }

  Future<bool> save(
      TeamSnapshotAttempt attempt, List<Assignment> items, DateTime savedAt) {
    if (!identical(attempt._issuer, _issuer) || attempt._used)
      return Future.value(false);
    attempt._used = true;
    if (project.trim().isEmpty) throw const FormatException('Missing project');
    for (final assignment in items) {
      if (HomeSnapshotCodec.assignmentFromMap(
              {'teamName': '', 'assignment': assignment.toJson()}) ==
          null) {
        throw const FormatException('Invalid assignment snapshot');
      }
    }
    // Encode before any await so mutable attachment maps cannot change in flight.
    final raw = jsonEncode({
      'schema': 2,
      'project': project,
      'uid': owner.userId,
      'teamId': owner.teamId,
      'savedAt': savedAt.toUtc().toIso8601String(),
      'items': items.map((item) => item.toJson()).toList()
    });
    bool current() =>
        _valid(attempt._ticket, attempt._ownerEpoch) &&
        coordinator._revisions[_key] == attempt._revision &&
        !coordinator._quarantined.contains(_key);
    return coordinator.serial(_key, () async {
      if (!current()) return false;
      final previous = await _read();
      if (!current()) return false;
      try {
        if (!await coordinator.storage.write(_key, raw))
          throw const TeamSnapshotStorageFailure();
      } catch (_) {
        await _restore(previous);
        throw const TeamSnapshotStorageFailure();
      }
      if (!current()) {
        await _restore(previous);
        return false;
      }
      return true;
    });
  }

  void _check(TeamCacheTicket ticket, int epoch) {
    if (project.trim().isEmpty) throw const FormatException('Missing project');
    if (!_valid(ticket, epoch)) throw StateError('Team cache owner changed');
    if (coordinator._quarantined.contains(_key))
      throw const TeamSnapshotStorageFailure();
  }

  Future<String?> _read() async {
    try {
      return await coordinator.storage.read(_key);
    } catch (_) {
      throw const TeamSnapshotStorageFailure();
    }
  }

  Future<void> _restore(String? previous) async {
    try {
      final ok = previous == null
          ? await coordinator.storage.remove(_key)
          : await coordinator.storage.write(_key, previous);
      if (!ok || await coordinator.storage.read(_key) != previous)
        throw const TeamSnapshotStorageFailure();
    } catch (_) {
      coordinator._quarantined.add(_key);
      throw const TeamSnapshotStorageFailure();
    }
  }

  void dispose() => _disposed = true;
}
