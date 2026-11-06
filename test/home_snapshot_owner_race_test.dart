import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';

class _Prefs implements SharedPreferences {
  final data = <String, String>{};
  final entered = Completer<void>();
  final release = Completer<void>();
  bool delayNext = true;
  bool failRemove = false;
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    if (delayNext) {
      delayNext = false;
      entered.complete();
      await release.future;
    }
    data[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    if (failRemove) return false;
    data.remove(key);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('stale write rolls back before new same-user session writes', () async {
    final prefs = _Prefs();
    var generation = 1;
    var identity = Object();
    final cache = HomeSnapshotCache(
        currentUserId: () => 'a',
        sessionGeneration: () => generation,
        sessionIdentity: () => identity,
        project: 'project-a',
        preferences: () async => prefs);
    final a = cache.captureScope('a')!;
    final old = cache.write(
        scope: a,
        section: HomeSnapshotSection.profile,
        items: [
          {'id': 'a', 'name': 'old'}
        ],
        savedAt: DateTime.now());
    await prefs.entered.future;
    generation++;
    identity = Object();
    final b = cache.captureScope('a')!;
    final fresh = cache.write(
        scope: b,
        section: HomeSnapshotSection.profile,
        items: [
          {'id': 'a', 'name': 'new'}
        ],
        savedAt: DateTime.now());
    final reading = cache.read('a', HomeSnapshotSection.profile);
    prefs.release.complete();
    expect(await old, isFalse);
    expect(await fresh, isTrue);
    expect((await reading)!.items.single['name'], 'new');
  });
  test('failed rollback quarantines v2 without blocking legacy snapshot',
      () async {
    final prefs = _Prefs();
    prefs.delayNext = false;
    var generation = 1;
    var identity = Object();
    HomeSnapshotCache make(String? project) => HomeSnapshotCache(
        currentUserId: () => 'b',
        sessionGeneration: () => generation,
        sessionIdentity: () => identity,
        project: project,
        preferences: () async => prefs);
    final legacy = make(null);
    final scoped = make('project-failure');
    final l = legacy.captureScope('b')!;
    expect(
        await legacy.write(
            scope: l,
            section: HomeSnapshotSection.profile,
            items: [
              {'name': 'legacy'}
            ],
            savedAt: DateTime.now()),
        isTrue);
    prefs.delayNext = true;
    prefs.failRemove = true;
    final old = scoped.write(
        scope: scoped.captureScope('b')!,
        section: HomeSnapshotSection.profile,
        items: [
          {'name': 'stale'}
        ],
        savedAt: DateTime.now());
    await prefs.entered.future;
    generation++;
    identity = Object();
    prefs.release.complete();
    expect(await old, isFalse);
    expect(await scoped.read('b', HomeSnapshotSection.profile), isNull);
    expect(
        (await legacy.read('b', HomeSnapshotSection.profile))!
            .items
            .single['name'],
        'legacy');
  });
}
