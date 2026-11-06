import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/models/schedule_group_action_event.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';

class _Reader implements CachedHomeScheduleReader {
  int calls = 0;
  @override
  Future<List<Lesson>?> readMonth(DateTime month) async {
    calls++;
    if (month.month != 11 || month.year != 2026) return null;
    return [
      Lesson(
          id: 'l',
          date: DateTime(2026, 11, 5),
          week: 1,
          day: 'ЧТ',
          pairNum: 1,
          start: const TimeOfDay(hour: 9, minute: 0),
          end: const TimeOfDay(hour: 10, minute: 0),
          subjectRaw: 'Сохранённый предмет')
    ];
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Repo implements ScheduleRepository {
  int calls = 0;
  @override
  Future<List<Lesson>> loadMonth(DateTime anchor, {bool strict = false}) async {
    calls++;
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation i) {
    calls++;
    return super.noSuchMethod(i);
  }
}

class _DeferredRepo implements ScheduleRepository {
  final requests = <Completer<List<Lesson>>>[];
  @override
  Future<List<Lesson>> loadMonth(DateTime anchor, {bool strict = false}) {
    final request = Completer<List<Lesson>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<List<ScheduleAssignment>> loadMonthAssignments(
          DateTime anchor) async =>
      [];
  @override
  Future<List<ScheduleGroupActionEvent>> loadMonthGroupActions(
          DateTime anchor) async =>
      [];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  testWidgets(
      'existing schedule displays cached lesson with no repository or realtime',
      (tester) async {
    final reader = _Reader(), repo = _Repo();
    await tester.pumpWidget(MaterialApp(
        home: ScheduleScreen(
            repository: repo,
            cachedReader: reader,
            now: () => DateTime(2026, 11, 5, 8))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Сохранённый предмет'), findsOneWidget);
    expect(reader.calls, greaterThan(0));
    expect(repo.calls, 0);
    await tester.tap(find.text('Сохранённый предмет'));
    await tester.pump();
    expect(find.text('Сохранённый предмет'), findsOneWidget);
    expect(repo.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('switch to cached schedule fences a delayed online response',
      (tester) async {
    final reader = _Reader(), repo = _DeferredRepo();
    Widget app(CachedHomeScheduleReader? cached) => MaterialApp(
        home: ScheduleScreen(
            key: const ValueKey('schedule'),
            repository: repo,
            cachedReader: cached,
            subscribeRealtime: false,
            now: () => DateTime(2026, 11, 5, 8)));
    await tester.pumpWidget(app(null));
    await tester.pump();
    expect(repo.requests.length, 1);
    await tester.pumpWidget(app(reader));
    await tester.pump();
    await tester.pump();
    expect(find.text('Сохранённый предмет'), findsOneWidget);
    repo.requests.first.complete([
      Lesson(
          id: 'old',
          date: DateTime(2026, 11, 5),
          week: 1,
          day: 'ЧТ',
          pairNum: 1,
          start: const TimeOfDay(hour: 9, minute: 0),
          end: const TimeOfDay(hour: 10, minute: 0),
          subjectRaw: 'Старый ответ')
    ]);
    await tester.pump();
    expect(find.text('Старый ответ'), findsNothing);
    expect(find.text('Сохранённый предмет'), findsOneWidget);
    await tester.pumpWidget(app(null));
    await tester.pump();
    expect(repo.requests.length, 2);
    repo.requests.last.complete([]);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
