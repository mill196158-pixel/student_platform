import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/learning/state/team_assignment_snapshot_store.dart';
import 'package:student_platform/src/ui/learning/state/team_cache_owner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Storage implements TeamSnapshotStorage {
  final values = <String, String>{};
  final failures = <String>[];
  Completer<void>? writeEntered, writeRelease;
  final removeGates = <Completer<void>>[];
  int removeCalls = 0;
  final keyGates = <Completer<void>>[];
  int keyCalls = 0;
  bool _fail(String kind) {
    if (failures.isEmpty || failures.first != kind) return false;
    failures.removeAt(0);
    return true;
  }

  @override
  Future<Set<String>> keys() async {
    final index = keyCalls++;
    if (index < keyGates.length) await keyGates[index].future;
    return values.keys.toSet();
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String value) async {
    writeEntered?.complete();
    await writeRelease?.future;
    values[key] = value;
    if (_fail('throw')) throw StateError('failed');
    return !_fail('false');
  }

  @override
  Future<bool> remove(String key) async {
    final index = removeCalls++;
    if (index < removeGates.length) await removeGates[index].future;
    values.remove(key);
    return !_fail('remove');
  }
}

void main() {
  late StreamController<AuthState> events;
  late Session session;
  late AuthSessionScope scope;
  late TeamCacheOwner owner;
  late _Storage storage;
  late TeamSnapshotCoordinator coordinator;
  late TeamAssignmentSnapshotStore store;
  final now = DateTime.utc(2026, 11, 5, 12);
  Assignment assignment(List<Map<String, String>> attachments) => Assignment(
      id: 'task',
      title: 'Task',
      description: '',
      published: true,
      votes: 2,
      completedByMe: true,
      createdBy: 'me',
      createdAt: now,
      attachments: attachments);
  setUp(() {
    events = StreamController<AuthState>.broadcast(sync: true);
    session = fakeSession('a');
    scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    owner = TeamCacheOwner.bind(scope, 'team')!;
    storage = _Storage();
    coordinator = TeamSnapshotCoordinator(storage);
    store = TeamAssignmentSnapshotStore(
        owner: owner, project: 'project', coordinator: coordinator);
  });
  tearDown(() async {
    store.dispose();
    owner.dispose();
    scope.dispose();
    await events.close();
  });

  test('roundtrip keeps fields, immutable attachments, and an empty hit',
      () async {
    final attachments = [
      {'name': 'doc', 'path': 'old'}
    ];
    final attempt = store.beginLoad()!;
    final pending = store.save(attempt, [assignment(attachments)], now);
    attachments.first['path'] = 'changed';
    expect(await pending, isTrue);
    final read = await store.read(owner.capture()!);
    expect(read.status, TeamSnapshotStatus.found);
    expect(read.assignments.single.completedByMe, isTrue);
    expect(read.assignments.single.dueAt, isNull);
    expect(read.assignments.single.attachments.single['path'], 'old');
    expect(() => read.assignments.single.attachments.first['x'] = 'y',
        throwsUnsupportedError);
    expect(await store.save(store.beginLoad()!, [], now), isTrue);
    final empty = await store.read(owner.capture()!);
    expect(empty.status, TeamSnapshotStatus.found);
    expect(empty.assignments, isEmpty);
  });
  test('latest started load wins even when older result arrives later',
      () async {
    final first = store.beginLoad()!;
    final second = store.beginLoad()!;
    expect(await store.save(second, [assignment([])], now), isTrue);
    expect(await store.save(first, [], now), isFalse);
    expect((await store.read(owner.capture()!)).assignments.single.id, 'task');
    expect(await store.save(second, [], now), isFalse);
  });
  test('project, team, user and ticket are isolated', () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final otherTeam = TeamCacheOwner.bind(scope, 'other')!;
    final teamStore = TeamAssignmentSnapshotStore(
        owner: otherTeam, project: 'project', coordinator: coordinator);
    final otherProject = TeamAssignmentSnapshotStore(
        owner: owner, project: 'other', coordinator: coordinator);
    expect((await teamStore.read(otherTeam.capture()!)).status,
        TeamSnapshotStatus.missing);
    expect((await otherProject.read(owner.capture()!)).status,
        TeamSnapshotStatus.missing);
    await expectLater(store.read(otherTeam.capture()!), throwsStateError);
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    final b = TeamCacheOwner.bind(scope, 'team')!;
    final bStore = TeamAssignmentSnapshotStore(
        owner: b, project: 'project', coordinator: coordinator);
    expect(
        (await bStore.read(b.capture()!)).status, TeamSnapshotStatus.missing);
    bStore.dispose();
    b.dispose();
    teamStore.dispose();
    otherProject.dispose();
    otherTeam.dispose();
  });
  test('malformed saved value remains corrupt rather than empty', () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final key = storage.values.keys.single;
    storage.values[key] = '{"schema":2}';
    expect((await store.read(owner.capture()!)).status,
        TeamSnapshotStatus.corrupt);
    expect(storage.values[key], '{"schema":2}');
  });
  test(
      'failed write restores previous snapshot and failed recovery quarantines',
      () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final previous = storage.values.values.single;
    storage.failures.add('false');
    await expectLater(store.save(store.beginLoad()!, [], now),
        throwsA(isA<TeamSnapshotStorageFailure>()));
    expect(storage.values.values.single, previous);
    storage.failures.addAll(['throw', 'false']);
    await expectLater(store.save(store.beginLoad()!, [], now),
        throwsA(isA<TeamSnapshotStorageFailure>()));
    await expectLater(store.read(owner.capture()!),
        throwsA(isA<TeamSnapshotStorageFailure>()));
  });
  test('logout during delayed write restores previous data', () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final previous = storage.values.values.single;
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final pending = store.save(store.beginLoad()!, [], now);
    await storage.writeEntered!.future;
    scope.invalidateForSignOut();
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    expect(await pending, isFalse);
    expect(storage.values.values.single, previous);
  });

  test('stores share latest-started revision and reject foreign attempts',
      () async {
    final other = TeamAssignmentSnapshotStore(
        owner: owner, project: 'project', coordinator: coordinator);
    final old = store.beginLoad()!;
    final fresh = other.beginLoad()!;
    expect(await store.save(fresh, [], now), isFalse);
    expect(await other.save(fresh, [assignment([])], now), isTrue);
    expect(await store.save(old, [], now), isFalse);
    expect((await store.read(owner.capture()!)).assignments.single.id, 'task');
    other.dispose();
  });

  test('dispose rolls back in-flight write before another store writes',
      () async {
    final other = TeamAssignmentSnapshotStore(
        owner: owner, project: 'project', coordinator: coordinator);
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final pending = store.save(store.beginLoad()!, [], now);
    await storage.writeEntered!.future;
    store.dispose();
    final next = other.save(other.beginLoad()!, [assignment([])], now);
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    expect(await pending, isFalse);
    expect(await next, isTrue);
    expect((await other.read(owner.capture()!)).assignments.single.id, 'task');
    other.dispose();
  });

  test('refresh invalidates pending load but a new load can save', () async {
    final stale = store.beginLoad()!;
    session = fakeSession('a', access: 'refreshed');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    expect(await store.save(stale, [], now), isFalse);
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
  });

  test('A to B to A invalidates previous store and attempt', () async {
    final stale = store.beginLoad()!;
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('a');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(await store.save(stale, [], now), isFalse);
    expect(store.beginLoad(), isNull);
  });

  test('clear fences immediately and waits for stale write rollback', () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final beforeClear = store.beginLoad()!;
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final pending = store.save(store.beginLoad()!, [], now);
    await storage.writeEntered!.future;
    final clear = coordinator.beginClear('project', 'a');
    expect(store.beginLoad(), isNull);
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    expect(await pending, isFalse);
    expect((await clear).complete, isTrue);
    expect(storage.values, isEmpty);
    expect((await store.read(owner.capture()!)).status,
        TeamSnapshotStatus.missing);
    expect(await store.save(beforeClear, [assignment([])], now), isFalse);
    final restarted = TeamAssignmentSnapshotStore(
        owner: owner,
        project: 'project',
        coordinator: TeamSnapshotCoordinator(storage));
    expect((await restarted.read(owner.capture()!)).status,
        TeamSnapshotStatus.missing);
    restarted.dispose();
  });

  test('failed removal stays fenced and retry removes even if memory is empty',
      () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    storage.failures.add('remove');
    expect((await coordinator.beginClear('project', 'a')).complete, isFalse);
    expect(storage.values, isEmpty);
    expect(store.beginLoad(), isNull);
    expect((await coordinator.beginClear('project', 'a')).complete, isTrue);
    expect(storage.removeCalls, 2);
    expect(store.beginLoad(), isNotNull);
  });

  test('clear finds an in-flight key absent from the storage scan', () async {
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final pending = store.save(store.beginLoad()!, [assignment([])], now);
    await storage.writeEntered!.future;
    expect(storage.values, isEmpty);
    final clear = coordinator.beginClear('project', 'a');
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    expect(await pending, isFalse);
    expect((await clear).complete, isTrue);
    expect(storage.values, isEmpty);
  });

  test('overlapping clears stay fenced until latest queued clear completes',
      () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final gate1 = Completer<void>();
    final gate2 = Completer<void>();
    storage.keyGates.addAll([gate1, gate2]);
    final first = coordinator.beginClear('project', 'a');
    final second = coordinator.beginClear('project', 'a');
    gate1.complete();
    expect((await first).complete, isTrue);
    expect(store.beginLoad(), isNull);
    gate2.complete();
    expect((await second).complete, isTrue);
    expect(store.beginLoad(), isNotNull);
  });

  test('clear leaves a different owner and unknown corrupt data untouched',
      () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final bEvents = StreamController<AuthState>.broadcast(sync: true);
    final bSession = fakeSession('b');
    final bScope = AuthSessionScope(
        currentSession: () => bSession, authEvents: bEvents.stream);
    bEvents.add(AuthState(AuthChangeEvent.initialSession, bSession));
    final b = TeamCacheOwner.bind(bScope, 'team')!;
    final bStore = TeamAssignmentSnapshotStore(
        owner: b, project: 'project', coordinator: coordinator);
    expect(
        await bStore.save(bStore.beginLoad()!, [assignment([])], now), isTrue);
    storage.values['team_assign_v2_unknown'] = '{broken';
    expect((await coordinator.beginClear('project', 'a')).complete, isFalse);
    expect((await bStore.read(b.capture()!)).status, TeamSnapshotStatus.found);
    expect(storage.values['team_assign_v2_unknown'], '{broken');
    expect(store.beginLoad(), isNotNull);
    bStore.dispose();
    b.dispose();
    bScope.dispose();
    await bEvents.close();
  });

  test('clear removes a registered owner key with corrupt identity fields',
      () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final key = storage.values.keys.single;
    storage.values[key] = '{"schema":2}';
    final result = await coordinator.beginClear('project', 'a');
    expect(result.complete, isTrue);
    expect(storage.values.containsKey(key), isFalse);
    expect(store.beginLoad(), isNotNull);
  });

  test('caller timeout does not cancel clear or unblock owner early', () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final gate = Completer<void>();
    storage.keyGates.add(gate);
    final clear = coordinator.beginClear('project', 'a');
    await expectLater(clear.timeout(const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()));
    expect(store.beginLoad(), isNull);
    gate.complete();
    expect((await clear).complete, isTrue);
    expect(store.beginLoad(), isNotNull);
  });

  test('same-account re-login waits for clear and uses a fresh owner',
      () async {
    expect(await store.save(store.beginLoad()!, [assignment([])], now), isTrue);
    final oldAttempt = store.beginLoad()!;
    final gate = Completer<void>();
    storage.keyGates.add(gate);
    final clear = coordinator.beginClear('project', 'a');
    scope.invalidateForSignOut();
    events.add(AuthState(AuthChangeEvent.signedOut, null));
    session = fakeSession('a', access: 'new-session');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    final freshOwner = TeamCacheOwner.bind(scope, 'team')!;
    final freshStore = TeamAssignmentSnapshotStore(
        owner: freshOwner, project: 'project', coordinator: coordinator);
    expect(freshStore.beginLoad(), isNull);
    gate.complete();
    expect((await clear).complete, isTrue);
    expect(await store.save(oldAttempt, [], now), isFalse);
    expect(
        await freshStore.save(freshStore.beginLoad()!, [assignment([])], now),
        isTrue);
    expect((await freshStore.read(freshOwner.capture()!)).status,
        TeamSnapshotStatus.found);
    freshStore.dispose();
    freshOwner.dispose();
  });
}
