import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../../home/home_snapshot_codec.dart';
import '../models/assignment.dart';
import 'team_cache_owner.dart';

abstract class TeamSnapshotStorage {
  Future<String?> read(String key);
  Future<bool> write(String key, String value);
  Future<bool> remove(String key);
}

class TeamSnapshotStorageFailure implements Exception {
  const TeamSnapshotStorageFailure();
}

class TeamSnapshotCoordinator {
  TeamSnapshotCoordinator(this.storage);
  final TeamSnapshotStorage storage;
  final _revisions = <String, int>{};
  final _queues = <String, Future<void>>{};
  final _quarantined = <String>{};

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
  TeamSnapshotAttempt._(this._issuer, this._ticket, this._revision);
  final Object _issuer;
  final TeamCacheTicket _ticket;
  final int _revision;
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

  String get _key => 'team_assign_v2_${sha256.convert(utf8.encode(jsonEncode([
            project,
            owner.userId,
            owner.teamId
          ])))}';
  bool _valid(TeamCacheTicket ticket) => !_disposed && owner.isCurrent(ticket);

  /// Capture before starting the corresponding network load.
  TeamSnapshotAttempt? beginLoad() {
    final ticket = owner.capture();
    if (ticket == null ||
        _disposed ||
        project.trim().isEmpty ||
        coordinator._quarantined.contains(_key)) return null;
    final revision = (coordinator._revisions[_key] ?? 0) + 1;
    coordinator._revisions[_key] = revision;
    return TeamSnapshotAttempt._(_issuer, ticket, revision);
  }

  Future<TeamAssignmentSnapshot> read(TeamCacheTicket ticket) =>
      coordinator.serial(_key, () async {
        _check(ticket);
        final raw = await _read();
        _check(ticket);
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
        _valid(attempt._ticket) &&
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

  void _check(TeamCacheTicket ticket) {
    if (project.trim().isEmpty) throw const FormatException('Missing project');
    if (!_valid(ticket)) throw StateError('Team cache owner changed');
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
