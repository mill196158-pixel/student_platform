import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/schedule/models/lesson.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

class _DelayedPreferences implements SharedPreferences {
  final values = <String, String>{};
  final started = Completer<void>();
  final finish = Completer<void>();
  bool delayNext = false;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    if (delayNext) {
      delayNext = false;
      started.complete();
      await finish.future;
    }
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('parallel reads do not invalidate a write before setString', () async {
    final session = fakeSession('schedule-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final prefs = _DelayedPreferences();
    final gate = Completer<SharedPreferences>();
    final cache =
        ScheduleMonthCache(scope, 'project', preferences: () => gate.future);
    final month = DateTime(2026, 11);
    final write = cache.write(cache.begin(month)!, []);
    final one = cache.beginRead(month)!;
    final two = cache.beginRead(month)!;
    expect(await cache.write(one, []), isFalse);
    final reads = Future.wait([cache.read(one), cache.read(two)]);
    gate.complete(prefs);
    expect(await write, isTrue);
    expect(await reads, [isEmpty, isEmpty]);
    scope.dispose();
    await events.close();
  });

  test('parallel reads do not invalidate an in-flight setString', () async {
    final session = fakeSession('schedule-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final prefs = _DelayedPreferences()..delayNext = true;
    final cache =
        ScheduleMonthCache(scope, 'project', preferences: () async => prefs);
    final month = DateTime(2026, 11);
    final write = cache.write(cache.begin(month)!, []);
    await prefs.started.future;
    final reads = Future.wait([
      cache.read(cache.beginRead(month)!),
      cache.read(cache.beginRead(month)!),
    ]);
    prefs.finish.complete();
    expect(await write, isTrue);
    expect(await reads, [isEmpty, isEmpty]);
    scope.dispose();
    await events.close();
  });
  test('month snapshots distinguish empty, missing, account and stale attempts',
      () async {
    SharedPreferences.setMockInitialValues({});
    var session = fakeSession('schedule-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final cache = ScheduleMonthCache(scope, 'project');
    final month = DateTime(2026, 11);
    final old = cache.begin(month)!;
    expect(await cache.read(old), isNull);
    expect(await cache.write(old, []), isTrue);
    expect(await cache.read(old), isEmpty);
    final newer = cache.begin(month)!;
    final lesson = Lesson(
        id: 'lesson',
        date: DateTime(2026, 11, 6),
        week: 1,
        day: 'ПТ',
        pairNum: 1,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 10, minute: 30),
        subjectRaw: 'Предмет');
    expect(await cache.write(old, [lesson]), isFalse);
    expect(await cache.write(newer, [lesson]), isTrue);
    expect((await cache.read(newer))!.single.subjectRaw, 'Предмет');
    final invalid = Lesson(
        id: '',
        date: lesson.date,
        week: 1,
        day: 'ПТ',
        pairNum: 1,
        start: lesson.start,
        end: lesson.end,
        subjectRaw: 'Ошибка');
    expect(await cache.write(newer, [invalid]), isFalse);
    expect((await cache.read(newer))!.single.subjectRaw, 'Предмет');
    final nextMonth = cache.begin(DateTime(2026, 12))!;
    expect(await cache.write(nextMonth, [lesson]), isFalse);
    expect(await cache.read(nextMonth), isNull);
    session = fakeSession('schedule-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await cache.read(newer), isNull);
    expect(await cache.read(cache.begin(month)!), isNull);
    scope.dispose();
    await events.close();
  });

  test('late disk read is discarded when account changes', () async {
    SharedPreferences.setMockInitialValues({});
    var session = fakeSession('schedule-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final gate = Completer<SharedPreferences>();
    final cache =
        ScheduleMonthCache(scope, 'project', preferences: () => gate.future);
    final attempt = cache.begin(DateTime(2026, 11))!;
    final result = cache.read(attempt);
    session = fakeSession('schedule-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    gate.complete(await SharedPreferences.getInstance());
    expect(await result, isNull);
    scope.dispose();
    await events.close();
  });

  test('account switch during a write restores the previous snapshot',
      () async {
    var session = fakeSession('schedule-a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final prefs = _DelayedPreferences();
    final cache =
        ScheduleMonthCache(scope, 'project', preferences: () async => prefs);
    final month = DateTime(2026, 11);
    expect(await cache.write(cache.begin(month)!, []), isTrue);
    final lesson = Lesson(
        id: 'lesson',
        date: DateTime(2026, 11, 6),
        week: 1,
        day: 'ПТ',
        pairNum: 1,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 10, minute: 30),
        subjectRaw: 'Предмет');
    prefs.delayNext = true;
    final pending = cache.write(cache.begin(month)!, [lesson]);
    await prefs.started.future;
    session = fakeSession('schedule-b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    prefs.finish.complete();
    expect(await pending, isFalse);
    session = fakeSession('schedule-a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await cache.read(cache.begin(month)!), isEmpty);
    scope.dispose();
    await events.close();
  });
}
