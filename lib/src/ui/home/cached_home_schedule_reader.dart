import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';

/// A local-only adapter. Construct only after an independent admission check;
/// it cannot authenticate an account or issue network requests.
class CachedHomeScheduleReader {
  CachedHomeScheduleReader({
    required SessionCapabilities capabilities,
    required HomeSnapshotCache home,
    required ScheduleMonthCache schedule,
  })  : _capabilities = capabilities,
        _home = home,
        _schedule = schedule,
        _permit = _capture(capabilities) {
    if (home.project == null ||
        home.project!.trim().isEmpty ||
        home.project != schedule.project ||
        home.authScope == null) {
      throw const CachedHomeAccessDenied();
    }
  }

  final SessionCapabilities _capabilities;
  final HomeSnapshotCache _home;
  final ScheduleMonthCache _schedule;
  final CapabilityPermit _permit;

  static CapabilityPermit _capture(SessionCapabilities capabilities) {
    final permit = capabilities.capture(SessionCapability.cachedRead);
    if (permit == null ||
        capabilities.mode != SessionCapabilityMode.cacheOnly) {
      throw const CachedHomeAccessDenied();
    }
    return permit;
  }

  void _check() {
    if (_capabilities.mode != SessionCapabilityMode.cacheOnly ||
        !_capabilities.permits(_permit, SessionCapability.cachedRead)) {
      throw const CachedHomeAccessDenied();
    }
  }

  /// Null means no valid snapshot, while an empty items list is saved data.
  Future<HomeSectionSnapshot?> readHome(HomeSnapshotSection section) async {
    _check();
    final owner = _home.authScope!.capture();
    if (owner == null || !_capabilities.owns(_permit, owner)) {
      throw const CachedHomeAccessDenied();
    }
    final value = await _home.read(_permit.userId, section);
    _check();
    return value;
  }

  /// Null means this month has not been saved; an empty list is a saved month.
  Future<List<Lesson>?> readMonth(DateTime month) async {
    _check();
    final attempt = _schedule.beginRead(month);
    if (attempt == null || !_capabilities.owns(_permit, attempt.owner)) {
      throw const CachedHomeAccessDenied();
    }
    final value = await _schedule.read(attempt);
    _check();
    return value == null ? null : List<Lesson>.unmodifiable(value);
  }
}

class CachedHomeAccessDenied implements Exception {
  const CachedHomeAccessDenied();
}
