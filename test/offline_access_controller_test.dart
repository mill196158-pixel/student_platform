import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/offline_access_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Session session(String uid, DateTime? expiry) {
  return Session(
    accessToken: 'test',
    tokenType: 'bearer',
    user: User(
        id: uid,
        appMetadata: const {},
        userMetadata: null,
        aud: '',
        createdAt: ''),
  )..expiresAt = expiry?.millisecondsSinceEpoch == null
      ? null
      : expiry!.millisecondsSinceEpoch ~/ 1000;
}

void main() {
  final now = DateTime.utc(2026, 11, 5);
  final later = now.add(const Duration(hours: 1));

  test('transport error allows only the current unexpired session', () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    var current = session('a', later);
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () async => throw TimeoutException('offline'),
    );
    expect(await controller.checkPolicy(), AccessDecision.offline);
    expect(controller.permitsOffline, isTrue);
    current = session('b', later);
    stream.add(AuthState(AuthChangeEvent.signedIn, current));
    expect(controller.permitsOffline, isFalse);
    controller.dispose();
    await stream.close();
  });

  test('late failures cannot allow a new session of the same user', () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    Session? current = session('a', later);
    final completer = Completer<bool>();
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () => completer.future,
    );
    final result = controller.checkPolicy();
    current = null;
    stream.add(const AuthState(AuthChangeEvent.signedOut, null));
    current = session('a', later);
    stream.add(AuthState(AuthChangeEvent.signedIn, current));
    completer.completeError(TimeoutException('offline'));
    expect(await result, AccessDecision.stale);
    expect(controller.permitsOffline, isFalse);
    controller.dispose();
    await stream.close();
  });

  test('missing or expired session and policy denial remain closed', () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    Session? current = session('a', now);
    var checks = 0;
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () async {
        checks++;
        throw const AuthApiException('denied', statusCode: '403');
      },
    );
    expect(await controller.checkPolicy(), AccessDecision.login);
    expect(checks, 0);
    current = session('a', later);
    stream.add(AuthState(AuthChangeEvent.signedIn, current));
    expect(await controller.checkPolicy(), AccessDecision.login);
    expect(controller.permitsOffline, isFalse);
    current = session('a', null);
    stream.add(AuthState(AuthChangeEvent.signedIn, current));
    expect(await controller.checkPolicy(), AccessDecision.login);
    expect(checks, 1);
    controller.dispose();
    await stream.close();
  });

  test('expiry on resume revokes access immediately', () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    var clock = now;
    final current = session('a', later);
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => clock,
      passwordChangeRequired: () async => throw TimeoutException('offline'),
    );
    expect(await controller.checkPolicy(), AccessDecision.offline);
    var updates = 0;
    controller.addListener(() => updates++);
    clock = later;
    controller.recheckExpiry();
    expect(controller.permitsOffline, isFalse);
    expect(updates, 1);
    controller.dispose();
    await stream.close();
  });

  test(
      'concurrent checks share one policy request; forced change stays online-only',
      () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    final current = session('a', later);
    final pending = Completer<bool>();
    var calls = 0;
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () {
        calls++;
        return pending.future;
      },
    );
    final a = controller.checkPolicy();
    final b = controller.checkPolicy();
    expect(calls, 1);
    pending.complete(true);
    expect(await a, AccessDecision.changePassword);
    expect(await b, AccessDecision.changePassword);
    expect(controller.permitsOffline, isFalse);
    controller.dispose();
    await stream.close();
  });

  test('refresh cannot extend the original offline access deadline', () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    var clock = now;
    var current = session('a', later);
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => clock,
      passwordChangeRequired: () async => throw TimeoutException('offline'),
    );
    expect(await controller.checkPolicy(), AccessDecision.offline);
    final generation = controller.generation;
    current = session('a', later.add(const Duration(hours: 1)));
    stream.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    expect(controller.generation, generation);
    clock = later;
    controller.recheckExpiry();
    expect(controller.permitsOffline, isFalse);
    controller.dispose();
    await stream.close();
  });

  test('retry immediately hides old access and supersedes a delayed request',
      () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    final current = session('a', later);
    final retry = Completer<bool>();
    var calls = 0;
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () {
        calls++;
        if (calls == 1) return Future.error(TimeoutException('offline'));
        return retry.future;
      },
    );
    expect(await controller.checkPolicy(), AccessDecision.offline);
    controller.revokeOffline();
    expect(controller.permitsOffline, isFalse);
    final a = controller.checkPolicy();
    final b = controller.checkPolicy();
    expect(calls, 2);
    controller.revokeOffline();
    retry.complete(false);
    expect(await a, AccessDecision.stale);
    expect(await b, AccessDecision.stale);
    expect(controller.permitsOffline, isFalse);
    controller.dispose();
    await stream.close();
  });

  test('auth stream errors do not grant access or escape listener', () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    final current = session('a', later);
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () async => false,
    );
    stream.addError(TimeoutException('offline'), StackTrace.current);
    expect(controller.permitsOffline, isFalse);
    expect(await controller.checkPolicy(), AccessDecision.allowed);
    controller.dispose();
    await stream.close();
  });

  test('dispose prevents late requests from granting admission', () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    final current = session('a', later);
    final pending = Completer<bool>();
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () => pending.future,
    );
    final result = controller.checkPolicy();
    controller.dispose();
    pending.completeError(TimeoutException('offline'));
    expect(await result, AccessDecision.stale);
    expect(controller.permitsOffline, isFalse);
    await stream.close();
  });

  test('new policy check immediately notifies removal of cached access',
      () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    final current = session('a', later);
    final pending = Completer<bool>();
    var calls = 0;
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () => ++calls == 1
          ? Future.error(TimeoutException('offline'))
          : pending.future,
    );
    expect(await controller.checkPolicy(), AccessDecision.offline);
    var notifications = 0;
    controller.addListener(() {
      notifications++;
      expect(controller.permitsOffline, isFalse);
      controller.checkPolicy();
    });
    final result = controller.checkPolicy();
    expect(notifications, 1);
    expect(calls, 2);
    pending.complete(false);
    expect(await result, AccessDecision.allowed);
    controller.dispose();
    await stream.close();
  });

  test('dispose invalidates an existing ticket and blocks further policy calls',
      () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    final current = session('a', later);
    var calls = 0;
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () async {
        calls++;
        throw TimeoutException('offline');
      },
    );
    expect(await controller.checkPolicy(), AccessDecision.offline);
    controller.dispose();
    expect(controller.permitsOffline, isFalse);
    expect(await controller.checkPolicy(), AccessDecision.stale);
    expect(calls, 1);
    await stream.close();
  });

  test('a replayed sign-in invalidates an old check and a fresh check succeeds',
      () async {
    final stream = StreamController<AuthState>.broadcast(sync: true);
    final current = session('a', later);
    final pending = Completer<bool>();
    var calls = 0;
    final controller = OfflineAccessController(
      currentSession: () => current,
      authEvents: stream.stream,
      now: () => now,
      passwordChangeRequired: () =>
          ++calls == 1 ? pending.future : Future.value(false),
    );
    final old = controller.checkPolicy();
    stream.add(AuthState(AuthChangeEvent.signedIn, current));
    pending.complete(false);
    expect(await old, AccessDecision.stale);
    expect(await controller.checkPolicy(), AccessDecision.allowed);
    controller.dispose();
    await stream.close();
  });
}
