import 'package:flutter/foundation.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
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
    _refreshRegistry[this] = (_homeRefresh, _scheduleRefresh);
  }

  final SessionCapabilities _capabilities;
  final HomeSnapshotCache _home;
  final ScheduleMonthCache _schedule;
  final CapabilityPermit _permit;
  final ValueNotifier<int> _homeRefresh = ValueNotifier<int>(0);
  final ValueNotifier<int> _scheduleRefresh = ValueNotifier<int>(0);
  final Map<Object, Future<Object?>> _pending = {};
  final Set<Object> _timedOut = {};
  final Map<Object, Object?> _late = {};
  static final Expando<(ValueNotifier<int>, ValueNotifier<int>)> _refreshRegistry = Expando();
  static Listenable? homeRefreshFor(CachedHomeScheduleReader? reader) =>
      reader == null ? null : _refreshRegistry[reader]?.$1;
  static Listenable? scheduleRefreshFor(CachedHomeScheduleReader? reader) =>
      reader == null ? null : _refreshRegistry[reader]?.$2;

  /// Lets a visible cache-only shell remove its data when admission is revoked.
  Listenable get accessChanges => _capabilities;
  Listenable get refreshChanges => _homeRefresh;
  bool get canRead =>
      _capabilities.mode == SessionCapabilityMode.cacheOnly &&
      _capabilities.permits(_permit, SessionCapability.cachedRead);

  bool permitsContent(SessionCapabilities contentCapabilities, CapabilityPermit permit) {
    final owner = _home.authScope!.capture();
    return canRead && owner != null && _capabilities.owns(_permit, owner) &&
        contentCapabilities.owns(permit, owner);
  }

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

  Future<T?> _bounded<T>(Object key, Future<T?> Function() load,
      AuthOperationScope owner, ValueNotifier<int> notifier) async {
    // Keep a completed late result for this cache-only reader. Re-consuming
    // it avoids staggered slow sections repeatedly waking each other up.
    if (_late.containsKey(key)) return _late[key] as T?;
    var work = _pending[key];
    if (work == null) {
      work = load();
      _pending[key] = work;
      final captured = work;
      work.then((value) {
        if (identical(_pending[key], captured)) _pending.remove(key);
        if (_timedOut.remove(key) && canRead && _capabilities.owns(_permit, owner)) {
          _late[key] = value;
          notifier.value++;
        }
      }, onError: (Object _, StackTrace __) {
        if (identical(_pending[key], captured)) _pending.remove(key);
        _timedOut.remove(key);
      });
    }
    return (await work.timeout(const Duration(seconds: 1), onTimeout: () {
      _timedOut.add(key);
      throw const CachedHomeTemporarilyUnavailable();
    })) as T?;
  }

  /// Null means no valid snapshot, while an empty items list is saved data.
  Future<HomeSectionSnapshot?> readHome(HomeSnapshotSection section) async {
    _check();
    final owner = _home.authScope!.capture();
    if (owner == null || !_capabilities.owns(_permit, owner)) {
      throw const CachedHomeAccessDenied();
    }
    final value = await _bounded<HomeSectionSnapshot>('home:${section.name}',
        () => _home.read(_permit.userId, section), owner, _homeRefresh);
    _check();
    return value;
  }

  /// Null means this month has not been saved; an empty list is a saved month.
  Future<List<Lesson>?> readMonth(DateTime month, {bool forDashboard = false}) async {
    _check();
    final attempt = _schedule.beginRead(MskDate.calendarDate(month));
    if (attempt == null || !_capabilities.owns(_permit, attempt.owner)) {
      throw const CachedHomeAccessDenied();
    }
    final day = MskDate.calendarDate(month);
    final value = await _bounded<List<Lesson>>('${forDashboard ? 'dashboardMonth' : 'month'}:${day.year}-${day.month}',
        () => _schedule.read(attempt, bounded: false), attempt.owner, forDashboard ? _homeRefresh : _scheduleRefresh);
    _check();
    return value == null ? null : List<Lesson>.unmodifiable(value);
  }

  /// Builds the existing dashboard model without constructing network APIs.
  /// Missing or malformed sections stay explicitly unavailable, not empty.
  Future<HomeDashboardData> readDashboard({DateTime? date}) async {
    _check();
    final day = MskDate.calendarDate(date ?? MskDate.today());
    Future<(HomeSectionSnapshot?, bool)> readSection(HomeSnapshotSection section) async {
      try { return (await readHome(section), false); }
      on CachedHomeTemporarilyUnavailable { return (null, true); }
    }
    final snapshots = await Future.wait([
      readSection(HomeSnapshotSection.profile),
      readSection(HomeSnapshotSection.schedule),
      readSection(HomeSnapshotSection.assignments),
    ]);
    _check();
    final profileSnapshot = snapshots[0].$1;
    final profileItems = profileSnapshot?.items;
    final validProfile = profileItems != null &&
        profileItems.length == 1 &&
        profileItems.first['id'] == _permit.userId;
    final profile = validProfile
        ? HomeUserProfile.fromMap(profileItems.first)
        : const HomeUserProfile();

    final scheduleSnapshot = snapshots[1].$1;
    var scheduleTemporarilyUnavailable = snapshots[1].$2;
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
      List<Lesson>? month;
      try { month = await readMonth(day, forDashboard: true); }
      on CachedHomeTemporarilyUnavailable { scheduleTemporarilyUnavailable = true; }
      _check();
      if (month != null) {
        lessons = month
            .where((lesson) => MskDate.isSameCalendarDate(lesson.date, day))
            .toList();
      }
    }
    List<HomeAssignmentPreview>? assignments;
    final savedAssignments = snapshots[2].$1;
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
          ? (scheduleTemporarilyUnavailable
              ? 'Сохранённое расписание временно недоступно'
              : 'Расписание ещё не сохранено')
          : 'Сохранённое расписание',
      assignmentsStatus: assignments == null
          ? (snapshots[2].$2
              ? 'Сохранённые задания временно недоступны'
              : 'Задания ещё не сохранены')
          : 'Сохранённые задания',
    );
  }
}

class CachedHomeAccessDenied implements Exception {
  const CachedHomeAccessDenied();
}

class CachedHomeTemporarilyUnavailable implements Exception {
  const CachedHomeTemporarilyUnavailable();
}
