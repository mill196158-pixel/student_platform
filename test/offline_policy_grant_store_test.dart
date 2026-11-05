import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/offline_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class MemoryStorage implements OfflineGrantStorage {
  final values = <String, String>{};
  Completer<void>? writeEntered, writeRelease, readEntered, readRelease;
  bool failWrite = false, failRemove = false;
  bool throwWrite = false;
  final List<Completer<void>> removeGates = [];
  int removeCalls = 0;
  @override
  Future<String?> read(String key) async {
    readEntered?.complete();
    await readRelease?.future;
    return values[key];
  }

  @override
  Future<bool> write(String key, String value) async {
    writeEntered?.complete();
    await writeRelease?.future;
    // Match SharedPreferences' cache-before-platform behavior.
    values[key] = value;
    if (throwWrite) throw StateError('storage failed');
    return !failWrite;
  }

  @override
  Future<bool> remove(String key) async {
    if (removeCalls < removeGates.length)
      await removeGates[removeCalls++].future;
    if (failRemove) return false;
    values.remove(key);
    return true;
  }
}

void main() {
  final now = DateTime.utc(2026, 11, 5);
  OfflineSessionBinding binding(String uid, String sid) =>
      OfflineSessionBinding(
          issuer: 'issuer',
          userId: uid,
          sessionId: sid,
          notBefore: now.subtract(const Duration(hours: 1)),
          expiresAt: now.add(const Duration(hours: 1)));
  OfflinePolicyGrant grant(OfflineSessionBinding b) => OfflinePolicyGrant(
      issuer: b.issuer,
      userId: b.userId,
      sessionId: b.sessionId,
      checkedAt: now,
      validUntil: now.add(const Duration(minutes: 30)));

  late StreamController<AuthState> events;
  late Session current;
  late AuthSessionScope scope;
  late OfflineSessionBinding currentBinding;
  late MemoryStorage storage;
  late OfflinePolicyGrantStore store;
  setUp(() {
    events = StreamController<AuthState>.broadcast(sync: true);
    current = fakeSession('a');
    scope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    currentBinding = binding('a', 'session-a');
    storage = MemoryStorage();
    store = OfflinePolicyGrantStore(
        session: scope, currentBinding: () => currentBinding, storage: storage);
  });
  tearDown(() async {
    store.dispose();
    scope.dispose();
    await events.close();
  });

  test('late live result cannot revive a synchronously revoked grant',
      () async {
    final owner = scope.capture()!;
    final attempt = store.beginLiveCheck(owner, currentBinding)!;
    await store.blockAndRevoke(currentBinding);
    expect(await store.saveAfterLiveCheck(attempt, grant(currentBinding)),
        isFalse);
    expect(storage.values, isEmpty);
  });
  test('revoke waits for in-flight write and removes its result', () async {
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final owner = scope.capture()!;
    final attempt = store.beginLiveCheck(owner, currentBinding)!;
    final save = store.saveAfterLiveCheck(attempt, grant(currentBinding));
    await storage.writeEntered!.future;
    final revoke = store.blockAndRevoke(currentBinding);
    expect(store.beginLiveCheck(owner, currentBinding), isNull);
    storage.writeRelease!.complete();
    expect(await save, isFalse);
    await revoke;
    expect(storage.values, isEmpty);
  });
  test('failed write is quarantined until an explicit successful revoke',
      () async {
    storage.failWrite = true;
    final owner = scope.capture()!;
    final attempt = store.beginLiveCheck(owner, currentBinding)!;
    await expectLater(store.saveAfterLiveCheck(attempt, grant(currentBinding)),
        throwsA(isA<OfflineGrantStorageException>()));
    expect(await store.read(owner, currentBinding), isNull);
    storage.failWrite = false;
    await store.blockAndRevoke(currentBinding);
    final fresh = store.beginLiveCheck(owner, currentBinding)!;
    expect(
        await store.saveAfterLiveCheck(fresh, grant(currentBinding)), isTrue);
    expect(await store.read(owner, currentBinding), isNotNull);
  });
  test(
      'failed revoke remains quarantined and throws, rather than reporting success',
      () async {
    final owner = scope.capture()!;
    final attempt = store.beginLiveCheck(owner, currentBinding)!;
    expect(
        await store.saveAfterLiveCheck(attempt, grant(currentBinding)), isTrue);
    storage.failRemove = true;
    await expectLater(store.blockAndRevoke(currentBinding),
        throwsA(isA<OfflineGrantStorageException>()));
    expect(await store.read(owner, currentBinding), isNull);
    expect(store.beginLiveCheck(owner, currentBinding), isNull);
  });
  test('account change while a read waits cannot return old grant', () async {
    final owner = scope.capture()!;
    final attempt = store.beginLiveCheck(owner, currentBinding)!;
    expect(
        await store.saveAfterLiveCheck(attempt, grant(currentBinding)), isTrue);
    storage.readEntered = Completer();
    storage.readRelease = Completer();
    final read = store.read(owner, currentBinding);
    await storage.readEntered!.future;
    current = fakeSession('b');
    currentBinding = binding('b', 'session-b');
    events.add(AuthState(AuthChangeEvent.signedIn, current));
    storage.readRelease!.complete();
    expect(await read, isNull);
  });
  test('token rotation keeps stored grant but revokes the old operation scope',
      () async {
    final owner = scope.capture()!;
    final attempt = store.beginLiveCheck(owner, currentBinding)!;
    expect(
        await store.saveAfterLiveCheck(attempt, grant(currentBinding)), isTrue);
    current = fakeSession('a', access: 'rotated');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    expect(await store.read(owner, currentBinding), isNull);
    expect(await store.read(scope.capture()!, currentBinding), isNotNull);
  });
  test('rotation during a write cleans the old result and allows a new check',
      () async {
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final attempt = store.beginLiveCheck(scope.capture()!, currentBinding)!;
    final pending = store.saveAfterLiveCheck(attempt, grant(currentBinding));
    await storage.writeEntered!.future;
    current = fakeSession('a', access: 'rotated');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    storage.writeRelease!.complete();
    expect(await pending, isFalse);
    expect(storage.values, isEmpty);
    expect(store.beginLiveCheck(scope.capture()!, currentBinding), isNotNull);
  });
  test('revoking A never deletes B grant', () async {
    final a = currentBinding;
    var owner = scope.capture()!;
    expect(
        await store.saveAfterLiveCheck(
            store.beginLiveCheck(owner, a)!, grant(a)),
        isTrue);
    current = fakeSession('b');
    currentBinding = binding('b', 'session-b');
    events.add(AuthState(AuthChangeEvent.signedIn, current));
    owner = scope.capture()!;
    expect(
        await store.saveAfterLiveCheck(
            store.beginLiveCheck(owner, currentBinding)!,
            grant(currentBinding)),
        isTrue);
    await store.blockAndRevoke(a);
    expect(await store.read(owner, currentBinding), isNotNull);
    expect(storage.values.length, 1);
  });
  test('logout and same-user re-entry cannot reuse a prior attempt', () async {
    final attempt = store.beginLiveCheck(scope.capture()!, currentBinding)!;
    scope.invalidateForSignOut();
    final revoked = store.blockAndRevoke(currentBinding);
    expect(await store.saveAfterLiveCheck(attempt, grant(currentBinding)),
        isFalse);
    await revoked;
    events.add(AuthState(AuthChangeEvent.signedOut, null));
    current = fakeSession('a', access: 'new-login');
    events.add(AuthState(AuthChangeEvent.signedIn, current));
    expect(await store.saveAfterLiveCheck(attempt, grant(currentBinding)),
        isFalse);
    expect(store.beginLiveCheck(scope.capture()!, currentBinding), isNotNull);
    expect(storage.values, isEmpty);
  });
  test('only newest live attempt may save and each attempt is single-use',
      () async {
    final owner = scope.capture()!;
    final old = store.beginLiveCheck(owner, currentBinding)!;
    final newer = store.beginLiveCheck(owner, currentBinding)!;
    expect(
        await store.saveAfterLiveCheck(newer, grant(currentBinding)), isTrue);
    expect(await store.saveAfterLiveCheck(old, grant(currentBinding)), isFalse);
    expect(
        await store.saveAfterLiveCheck(newer, grant(currentBinding)), isFalse);
    expect(await store.read(owner, currentBinding), isNotNull);
  });
  test('stale denial cannot revoke a newer grant, and revoke is single-use',
      () async {
    final owner = scope.capture()!;
    final old = store.beginLiveCheck(owner, currentBinding)!;
    final fresh = store.beginLiveCheck(owner, currentBinding)!;
    expect(
        await store.saveAfterLiveCheck(fresh, grant(currentBinding)), isTrue);
    expect(await store.revokeAfterLiveCheck(old), isFalse);
    expect(await store.read(owner, currentBinding), isNotNull);
    final deny = store.beginLiveCheck(owner, currentBinding)!;
    expect(await store.revokeAfterLiveCheck(deny), isTrue);
    expect(await store.revokeAfterLiveCheck(deny), isFalse);
    expect(await store.read(owner, currentBinding), isNull);
  });
  test('newer live check wins when old write completes late', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    storage.writeEntered = entered;
    storage.writeRelease = release;
    final owner = scope.capture()!;
    final older = store.beginLiveCheck(owner, currentBinding)!;
    final oldWrite = store.saveAfterLiveCheck(older, grant(currentBinding));
    await entered.future;
    final newer = store.beginLiveCheck(owner, currentBinding)!;
    final newWrite = store.saveAfterLiveCheck(newer, grant(currentBinding));
    storage.writeEntered = null;
    storage.writeRelease = null;
    release.complete();
    expect(await oldWrite, isFalse);
    expect(await newWrite, isTrue);
    expect(await store.read(owner, currentBinding), isNotNull);
  });
  test('throwing write quarantines cached value until revoke succeeds',
      () async {
    storage.throwWrite = true;
    final owner = scope.capture()!;
    final attempt = store.beginLiveCheck(owner, currentBinding)!;
    await expectLater(store.saveAfterLiveCheck(attempt, grant(currentBinding)),
        throwsA(isA<OfflineGrantStorageException>()));
    expect(await store.read(owner, currentBinding), isNull);
    storage.throwWrite = false;
    await store.blockAndRevoke(currentBinding);
    expect(storage.values, isEmpty);
  });
  test('double revoke keeps the fence until the newest revoke completes',
      () async {
    storage.removeGates.addAll([Completer<void>(), Completer<void>()]);
    final first = store.blockAndRevoke(currentBinding);
    final second = store.blockAndRevoke(currentBinding);
    storage.removeGates[0].complete();
    await first;
    expect(store.beginLiveCheck(scope.capture()!, currentBinding), isNull);
    storage.removeGates[1].complete();
    await second;
    expect(store.beginLiveCheck(scope.capture()!, currentBinding), isNotNull);
  });
  test('dispose while writing discards the late value', () async {
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final attempt = store.beginLiveCheck(scope.capture()!, currentBinding)!;
    final pending = store.saveAfterLiveCheck(attempt, grant(currentBinding));
    await storage.writeEntered!.future;
    store.dispose();
    storage.writeRelease!.complete();
    expect(await pending, isFalse);
    expect(storage.values, isEmpty);
  });
  test(
      'shared coordinator serializes stale cleanup before replacement store writes',
      () async {
    final coordinator = OfflineGrantCoordinator(storage);
    final oldStore = OfflinePolicyGrantStore(
        session: scope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    final otherScope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final replacement = OfflinePolicyGrantStore(
        session: otherScope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    final entered = Completer<void>(), release = Completer<void>();
    storage.writeEntered = entered;
    storage.writeRelease = release;
    final old = oldStore.beginLiveCheck(scope.capture()!, currentBinding)!;
    final oldWrite = oldStore.saveAfterLiveCheck(old, grant(currentBinding));
    await entered.future;
    oldStore.dispose();
    final fresh =
        replacement.beginLiveCheck(otherScope.capture()!, currentBinding)!;
    final newWrite =
        replacement.saveAfterLiveCheck(fresh, grant(currentBinding));
    storage.writeEntered = null;
    storage.writeRelease = null;
    release.complete();
    expect(await oldWrite, isFalse);
    expect(await newWrite, isTrue);
    expect(await replacement.read(otherScope.capture()!, currentBinding),
        isNotNull);
    replacement.dispose();
    otherScope.dispose();
  });
  test('failed old cleanup quarantines a shared replacement', () async {
    final coordinator = OfflineGrantCoordinator(storage);
    final oldStore = OfflinePolicyGrantStore(
        session: scope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    final otherScope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final replacement = OfflinePolicyGrantStore(
        session: otherScope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    final entered = Completer<void>(), release = Completer<void>();
    storage.writeEntered = entered;
    storage.writeRelease = release;
    final old = oldStore.beginLiveCheck(scope.capture()!, currentBinding)!;
    final oldWrite = oldStore.saveAfterLiveCheck(old, grant(currentBinding));
    await entered.future;
    oldStore.dispose();
    final fresh =
        replacement.beginLiveCheck(otherScope.capture()!, currentBinding)!;
    final newWrite =
        replacement.saveAfterLiveCheck(fresh, grant(currentBinding));
    storage.writeEntered = null;
    storage.writeRelease = null;
    storage.failRemove = true;
    release.complete();
    await expectLater(oldWrite, throwsA(isA<OfflineGrantStorageException>()));
    expect(await newWrite, isFalse);
    expect(
        await replacement.read(otherScope.capture()!, currentBinding), isNull);
    replacement.dispose();
    otherScope.dispose();
  });
  test('revoke fences both old and replacement stores during a delayed write',
      () async {
    final coordinator = OfflineGrantCoordinator(storage);
    final oldStore = OfflinePolicyGrantStore(
        session: scope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    final otherScope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final replacement = OfflinePolicyGrantStore(
        session: otherScope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    final entered = Completer<void>(), release = Completer<void>();
    storage.writeEntered = entered;
    storage.writeRelease = release;
    final old = oldStore.beginLiveCheck(scope.capture()!, currentBinding)!;
    final oldWrite = oldStore.saveAfterLiveCheck(old, grant(currentBinding));
    await entered.future;
    oldStore.dispose();
    final fresh =
        replacement.beginLiveCheck(otherScope.capture()!, currentBinding)!;
    final newWrite =
        replacement.saveAfterLiveCheck(fresh, grant(currentBinding));
    final revoke = replacement.blockAndRevoke(currentBinding);
    storage.writeEntered = null;
    storage.writeRelease = null;
    release.complete();
    expect(await oldWrite, isFalse);
    expect(await newWrite, isFalse);
    await revoke;
    expect(storage.values, isEmpty);
    replacement.dispose();
    otherScope.dispose();
  });
  test('disposed store cannot revoke a replacement store grant', () async {
    final coordinator = OfflineGrantCoordinator(storage);
    final oldStore = OfflinePolicyGrantStore(
        session: scope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    final replacement = OfflinePolicyGrantStore(
        session: scope,
        currentBinding: () => currentBinding,
        coordinator: coordinator);
    oldStore.dispose();
    final owner = scope.capture()!;
    final attempt = replacement.beginLiveCheck(owner, currentBinding)!;
    expect(await replacement.saveAfterLiveCheck(attempt, grant(currentBinding)),
        isTrue);
    await expectLater(
        oldStore.blockAndRevoke(currentBinding), throwsStateError);
    expect(await replacement.read(owner, currentBinding), isNotNull);
    replacement.dispose();
  });
}
