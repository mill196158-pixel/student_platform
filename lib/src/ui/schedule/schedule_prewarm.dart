import 'dart:async';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'models/lesson.dart';
import 'schedule_month_cache.dart';
import 'utils/msk_date.dart';

/// Saves only successful full months in a separate low-priority namespace.
class SchedulePrewarm {
  SchedulePrewarm({required this.scope, required this.cache,
    required this.barrier, required this.loadMonth}) {
  }
  final AuthSessionScope scope;
  final ScheduleMonthCache cache;
  final OnlineSideEffectBarrier barrier;
  final Future<List<Lesson>> Function(DateTime month) loadMonth;
  static final _inFlight = <(String, AuthOperationScope, int, int, OnlineSideEffectBarrier), Future<void>>{};

  Future<void> warm(DateTime date) async {
    final day = MskDate.calendarDate(date);
    final monday = day.subtract(Duration(days: day.weekday - 1));
    final sunday = monday.add(const Duration(days: 6));
    final months = <DateTime>{DateTime(day.year, day.month),
      DateTime(monday.year, monday.month), DateTime(sunday.year, sunday.month)};
    for (final month in months) {
      if (!barrier.isOpen) return;
      final owner = scope.capture();
      if (owner == null || !scope.isCurrent(owner)) return;
      final key = (cache.project, owner, month.year, month.month, barrier);
      final existing = _inFlight[key];
      if (existing != null) { await existing; continue; }
      final work = _load(owner, month);
      _inFlight[key] = work;
      try { await work; } finally {
        if (identical(_inFlight[key], work)) _inFlight.remove(key);
      }
    }
  }

  Future<void> _load(AuthOperationScope owner, DateTime month) async {
    final attempt = cache.beginBackground(month);
    if (attempt == null || attempt.owner != owner) return;
    try {
      await barrier.run(() async {
        if (!scope.isCurrent(owner) || !barrier.isOpen) return;
        final items = await loadMonth(month);
        if (!scope.isCurrent(owner) || !barrier.isOpen) return;
        await cache.write(attempt, items,
            isCurrent: () => scope.isCurrent(owner) && barrier.isOpen);
      });
    } catch (_) {
      // Never replace the last successful snapshot on failed/invalid loads.
    }
  }
}
