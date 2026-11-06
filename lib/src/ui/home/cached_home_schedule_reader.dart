import 'package:flutter/foundation.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/home/home_snapshot_codec.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';

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

  /// Lets a visible cache-only shell remove its data when admission is revoked.
  Listenable get accessChanges => _capabilities;
  bool get canRead =>
      _capabilities.mode == SessionCapabilityMode.cacheOnly &&
      _capabilities.permits(_permit, SessionCapability.cachedRead);

  static CapabilityPermit _capture(SessionCapabilities capabilities) {
    final permit = capabilities.capture(SessionCapability.cachedRead);
    if (permit == null ||
        capabilities.mode != SessionCapabilityMode.cacheOnly) {
      throw const CachedHomeAccessDenied();
    }
    return permit;
  }

  void _check() {
    if (!canRead) {
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
    final attempt = _schedule.beginRead(MskDate.calendarDate(month));
    if (attempt == null || !_capabilities.owns(_permit, attempt.owner)) {
      throw const CachedHomeAccessDenied();
    }
    final value = await _schedule.read(attempt);
    _check();
    return value == null ? null : List<Lesson>.unmodifiable(value);
  }

  /// Builds the existing dashboard model without constructing network APIs.
  /// Missing or malformed sections stay explicitly unavailable, not empty.
  Future<HomeDashboardData> readDashboard({DateTime? date}) async {
    _check();
    final day = MskDate.calendarDate(date ?? MskDate.today());
    final snapshots = await Future.wait([
      readHome(HomeSnapshotSection.profile),
      readHome(HomeSnapshotSection.schedule),
      readHome(HomeSnapshotSection.assignments),
    ]);
    _check();
    final profileSnapshot = snapshots[0];
    final profileItems = profileSnapshot?.items;
    final validProfile = profileItems != null &&
        profileItems.length == 1 &&
        profileItems.first['id'] == _permit.userId;
    final profile = validProfile
        ? HomeUserProfile.fromMap(profileItems.first)
        : const HomeUserProfile();

    final scheduleSnapshot = snapshots[1];
    List<Lesson>? lessons;
    if (scheduleSnapshot != null &&
        scheduleSnapshot.date == MskDate.isoDate(day)) {
      final decoded =
          scheduleSnapshot.items.map(HomeSnapshotCodec.lessonFromMap).toList();
      if (decoded.every((item) =>
          item != null && MskDate.isSameCalendarDate(item.date, day))) {
        lessons = decoded.cast<Lesson>();
      }
    }
    if (lessons == null) {
      final month = await readMonth(day);
      _check();
      if (month != null) {
        lessons = month
            .where((lesson) => MskDate.isSameCalendarDate(lesson.date, day))
            .toList();
      }
    }
    List<HomeAssignmentPreview>? assignments;
    final savedAssignments = snapshots[2];
    if (savedAssignments != null) {
      final decoded = savedAssignments.items
          .map(HomeSnapshotCodec.assignmentFromMap)
          .toList();
      if (decoded.every((item) => item != null)) {
        assignments = decoded.cast<HomeAssignmentPreview>();
      }
    }
    _check();
    return HomeDashboardData(
      profile: profile,
      scheduleDate: day,
      todayLessons: List<Lesson>.unmodifiable(lessons ?? const []),
      assignments:
          List<HomeAssignmentPreview>.unmodifiable(assignments ?? const []),
      news: const [],
      scheduleStatus: lessons == null
          ? 'Расписание ещё не сохранено'
          : 'Сохранённое расписание',
      assignmentsStatus: assignments == null
          ? 'Задания ещё не сохранены'
          : 'Сохранённые задания',
    );
  }
}

class CachedHomeAccessDenied implements Exception {
  const CachedHomeAccessDenied();
}
