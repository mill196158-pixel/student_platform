import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('empty and missing snapshots remain distinct and user scoped', () async {
    var uid = 'a';
    var generation = 1;
    final cache = HomeSnapshotCache(
        currentUserId: () => uid,
        sessionGeneration: () => generation,
        sessionIdentity: () => uid);
    expect(await cache.read('a', HomeSnapshotSection.schedule), isNull);
    expect(
        await cache.write(
            scope: cache.captureScope('a')!,
            section: HomeSnapshotSection.schedule,
            items: [],
            date: '2026-11-05',
            savedAt: DateTime.utc(2026)),
        isTrue);
    final empty = await cache.read('a', HomeSnapshotSection.schedule);
    expect(empty, isNotNull);
    expect(empty!.items, isEmpty);
    expect(empty.date, '2026-11-05');
    uid = 'b';
    generation++;
    expect(await cache.read('a', HomeSnapshotSection.schedule), isNull);
    expect(await cache.read('b', HomeSnapshotSection.schedule), isNull);
  });

  test('late writes from a previous login cannot overwrite a newer session',
      () async {
    var generation = 1;
    final pending = Completer<SharedPreferences>();
    final cache = HomeSnapshotCache(
        currentUserId: () => 'a',
        sessionGeneration: () => generation,
        sessionIdentity: () => 'session',
        preferences: () => pending.future);
    final write = cache.write(
        scope: cache.captureScope('a')!,
        section: HomeSnapshotSection.assignments,
        items: [
          {'title': 'old'}
        ],
        savedAt: DateTime.utc(2026));
    generation += 2;
    pending.complete(await SharedPreferences.getInstance());
    expect(await write, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((x) => x.startsWith('home_snapshot_v1_')),
        isEmpty);
  });

  test('corrupt snapshot is not treated as an empty result', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('home_snapshot_v1_assignments_a', '{broken');
    final cache = HomeSnapshotCache(
        currentUserId: () => 'a',
        sessionGeneration: () => 1,
        sessionIdentity: () => 'session');
    expect(await cache.read('a', HomeSnapshotSection.assignments), isNull);
  });

  test('changed credentials block a late write before auth event arrives',
      () async {
    Object identity = Object();
    final pending = Completer<SharedPreferences>();
    final cache = HomeSnapshotCache(
        currentUserId: () => 'a',
        sessionGeneration: () => 1,
        sessionIdentity: () => identity,
        preferences: () => pending.future);
    final write = cache.write(
        scope: cache.captureScope('a')!,
        section: HomeSnapshotSection.schedule,
        items: [],
        date: '2026-11-05',
        savedAt: DateTime.utc(2026));
    identity = Object();
    pending.complete(await SharedPreferences.getInstance());
    expect(await write, isFalse);
  });

  test('older write cannot overwrite a newer response for the same section',
      () async {
    final pending = Completer<SharedPreferences>();
    var calls = 0;
    final cache = HomeSnapshotCache(
        currentUserId: () => 'a',
        sessionGeneration: () => 1,
        sessionIdentity: () => 'a-session',
        preferences: () {
          calls++;
          return calls == 1 ? pending.future : SharedPreferences.getInstance();
        });
    final old = cache.write(
        scope: cache.captureScope('a')!,
        section: HomeSnapshotSection.assignments,
        items: [
          {'value': 'old'}
        ],
        savedAt: DateTime.utc(2026));
    final fresh = cache.write(
        scope: cache.captureScope('a')!,
        section: HomeSnapshotSection.assignments,
        items: [
          {'value': 'new'}
        ],
        savedAt: DateTime.utc(2026));
    pending.complete(await SharedPreferences.getInstance());
    expect(await old, isFalse);
    expect(await fresh, isTrue);
    expect(
        (await cache.read('a', HomeSnapshotSection.assignments))!
            .items
            .single['value'],
        'new');
  });

  test('scope captured before RPC rejects a late response after re-login',
      () async {
    var generation = 1;
    final cache = HomeSnapshotCache(
        currentUserId: () => 'a',
        sessionGeneration: () => generation,
        sessionIdentity: () => 'token');
    final beforeRequest = cache.captureScope('a')!;
    generation += 2;
    expect(
        await cache.write(
            scope: beforeRequest,
            section: HomeSnapshotSection.schedule,
            items: [],
            savedAt: DateTime.utc(2026)),
        isFalse);
  });
}
