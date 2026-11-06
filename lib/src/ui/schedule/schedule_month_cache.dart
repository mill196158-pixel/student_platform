import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/home/home_snapshot_codec.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';

/// Account-scoped last successful full-month lesson snapshots.
class ScheduleMonthCache {
  ScheduleMonthCache(this.scope, this.project,
      {Future<SharedPreferences> Function()? preferences})
      : _preferences = preferences ?? SharedPreferences.getInstance;

  final AuthSessionScope scope;
  final String project;
  final Future<SharedPreferences> Function() _preferences;
  static final _versions = <String, int>{};
  static final _pending = <String, Future<void>>{};
  static final _quarantined = <String>{};
  static final _foreground = <String, ScheduleMonthAttempt>{};

  String _month(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}';
  String _key(String userId, DateTime month) =>
      'schedule_month_v1_${sha256.convert(utf8.encode(jsonEncode([
            project,
            userId,
            _month(month)
          ])))}';

  ScheduleMonthAttempt? begin(DateTime month) {
    final owner = scope.capture();
    if (owner == null) return null;
    final key = _key(owner.userId, month);
    final version = (_versions[key] ?? 0) + 1;
    _versions[key] = version;
    final attempt = ScheduleMonthAttempt._(owner, key, _month(month), version, true);
    _foreground[key] = attempt;
    return attempt;
  }

  /// A background request never invalidates an active foreground load.
  ScheduleMonthAttempt? beginBackground(DateTime month) {
    final owner = scope.capture();
    if (owner == null) return null;
    final key = _key(owner.userId, month);
    final active = _foreground[key];
    if (active != null && scope.isCurrent(active.owner)) return null;
    if (active != null) _foreground.remove(key);
    final version = (_versions[key] ?? 0) + 1;
    _versions[key] = version;
    return ScheduleMonthAttempt._(owner, key, _month(month), version, true);
  }

  void finishForeground(ScheduleMonthAttempt attempt) {
    if (identical(_foreground[attempt.key], attempt)) _foreground.remove(attempt.key);
  }

  /// Captures the current version without invalidating in-flight writes or
  /// other readers. A newer write still invalidates this read.
  ScheduleMonthAttempt? beginRead(DateTime month) {
    final owner = scope.capture();
    if (owner == null) return null;
    final key = _key(owner.userId, month);
    return ScheduleMonthAttempt._(
        owner, key, _month(month), _versions[key] ?? 0, false);
  }

  bool _current(ScheduleMonthAttempt attempt) =>
      scope.isCurrent(attempt.owner) &&
      (_versions[attempt.key] ?? 0) == attempt.version;

  Future<List<Lesson>?> read(ScheduleMonthAttempt attempt) async {
    if (!_current(attempt)) return null;
    try {
      final pending = _pending[attempt.key];
      if (pending != null) {
        try {
          await pending.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          return null;
        }
      }
      if (!_current(attempt) || _quarantined.contains(attempt.key) ||
          _pending.containsKey(attempt.key)) return null;
      final prefs = await _preferences();
      if (!_current(attempt) || _quarantined.contains(attempt.key) ||
          _pending.containsKey(attempt.key)) return null;
      final raw = prefs.getString(attempt.key);
      if (raw == null) return null;
      final json = jsonDecode(raw);
      if (json is! Map ||
          json['version'] != 1 ||
          json['owner'] != attempt.owner.userId ||
          json['month'] != attempt.month ||
          json['items'] is! List) return null;
      final lessons = <Lesson>[];
      for (final row in json['items'] as List) {
        if (row is! Map || row.keys.any((key) => key is! String)) return null;
        final lesson =
            HomeSnapshotCodec.lessonFromMap(Map<String, dynamic>.from(row));
        if (lesson == null ||
            !MskDate.isoDate(lesson.date).startsWith('${attempt.month}-'))
          return null;
        lessons.add(lesson);
      }
      return _current(attempt) ? lessons : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> write(ScheduleMonthAttempt attempt, List<Lesson> lessons,
      {bool Function()? isCurrent}) async {
    bool current() {
      try { return _current(attempt) && (isCurrent?.call() ?? true); }
      catch (_) { return false; }
    }
    if (!attempt._writable ||
        !current() ||
        lessons.any((lesson) =>
            !MskDate.isoDate(lesson.date).startsWith('${attempt.month}-')))
      return false;
    final rows = lessons.map(HomeSnapshotCodec.lessonToMap).toList();
    if (rows.any((row) => HomeSnapshotCodec.lessonFromMap(row) == null))
      return false;
    final raw = jsonEncode({
      'version': 1,
      'owner': attempt.owner.userId,
      'month': attempt.month,
      'items': rows
    });
    final previous = _pending[attempt.key];
    final done = Completer<void>();
    _pending[attempt.key] = done.future;
    try {
      if (previous != null) await previous;
      if (!current()) return false;
      final prefs = await _preferences();
      if (!current()) return false;
      final previousValue = prefs.getString(attempt.key);
      final wasQuarantined = _quarantined.contains(attempt.key);
      _quarantined.add(attempt.key);
      try {
        final saved = await prefs.setString(attempt.key, raw);
        if (saved && current()) {
          _quarantined.remove(attempt.key);
          return true;
        }
      } catch (_) {
        // Restore the last good value before allowing another read.
      }
      try {
        final restored = previousValue == null
            ? await prefs.remove(attempt.key)
            : await prefs.setString(attempt.key, previousValue);
        if (restored && !wasQuarantined) _quarantined.remove(attempt.key);
      } catch (_) {
        // Retain the in-process quarantine on storage failure.
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      done.complete();
      if (identical(_pending[attempt.key], done.future))
        _pending.remove(attempt.key);
    }
  }
}

class ScheduleMonthAttempt {
  const ScheduleMonthAttempt._(
      this.owner, this.key, this.month, this.version, this._writable);
  final AuthOperationScope owner;
  final String key;
  final String month;
  final int version;
  final bool _writable;
}
