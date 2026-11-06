import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';

class DelayedPreferences implements SharedPreferences {
  final values = <String, String>{};
  Completer<void>? entered;
  Completer<void>? release;
  bool failRemove = false;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    final wait = release;
    if (wait != null) {
      release = null;
      entered!.complete();
      await wait.future;
    }
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    if (failRemove) return false;
    values.remove(key);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('legacy read waits for stale write and sees newer owner data', () async {
    final prefs = DelayedPreferences();
    var generation = 0;
    var identity = Object();
    var uid = 'a';
    final cache = HomeSnapshotCache(
      currentUserId: () => uid,
      sessionGeneration: () => generation,
      sessionIdentity: () => identity,
      preferences: () async => prefs,
    );
    Future<bool> write(String name) => cache.write(
          scope: cache.captureScope('a')!,
          section: HomeSnapshotSection.profile,
          items: [{'id': 'a', 'name': name}],
          savedAt: DateTime.utc(2026),
        );
    expect(await write('before'), isTrue);
    prefs.entered = Completer<void>();
    final release = Completer<void>();
    prefs.release = release;
    final stale = write('old');
    await prefs.entered!.future;
    uid = 'b';
    generation++;
    identity = Object();
    uid = 'a';
    generation++;
    identity = Object();
    final fresh = write('new');
    final read = cache.read('a', HomeSnapshotSection.profile);
    release.complete();
    expect(await stale, isFalse);
    expect(await fresh, isTrue);
    expect((await read)!.items.single['name'], 'new');
  });

  test('legacy pending read fails closed and rollback failure quarantines', () async {
    final prefs = DelayedPreferences();
    var generation = 0;
    var identity = Object();
    final cache = HomeSnapshotCache(
      currentUserId: () => 'a',
      sessionGeneration: () => generation,
      sessionIdentity: () => identity,
      preferences: () async => prefs,
    );
    Future<bool> write(String name) => cache.write(
          scope: cache.captureScope('a')!,
          section: HomeSnapshotSection.profile,
          items: [{'id': 'a', 'name': name}],
          savedAt: DateTime.utc(2026),
        );
    prefs.entered = Completer<void>();
    final release = Completer<void>();
    prefs.release = release;
    final stale = write('old');
    await prefs.entered!.future;
    generation++;
    identity = Object();
    expect(await cache.read('a', HomeSnapshotSection.profile), isNull);
    prefs.failRemove = true;
    release.complete();
    expect(await stale, isFalse);
    expect(await cache.read('a', HomeSnapshotSection.profile), isNull);
    prefs.failRemove = false;
    expect(await write('new'), isTrue);
    expect((await cache.read('a', HomeSnapshotSection.profile))!.items.single['name'], 'new');
  });
}
