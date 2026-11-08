import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/reconnect_transition_fence_experiment.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  test('unknown perimeter rejects unobservable A-B-A even when scope equality revives', () async {
    var session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final oldOwner = scope.capture()!;
    final signals = ValueNotifier(0);
    final unknown = ReconnectTransitionFenceExperiment(scope: scope, authSignals: signals);
    session = fakeSession('b');
    session = fakeSession('a');
    expect(scope.isCurrent(oldOwner), isTrue);
    expect(unknown.capture(), isNull);
    unknown.dispose(); scope.dispose(); signals.dispose(); await events.close();
  });

  test('in-flight or uninspectable operations cannot issue or use a ticket', () async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final signals = ValueNotifier(0);
    var quiet = false, fail = false;
    final fence = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope,
        authSignals: signals, isQuiescent: () { if (fail) throw StateError('unknown'); return quiet; });
    expect(fence.capture(), isNull);
    expect(fence.capture(), isNull);
    fence.dispose();
    quiet = true;
    final clean = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope,
        authSignals: signals, isQuiescent: () { if (fail) throw StateError('unknown'); return quiet; });
    final ticket = clean.capture()!;
    quiet = false;
    expect(clean.permits(ticket), isFalse);
    quiet = true;
    expect(clean.permits(ticket), isFalse);
    fail = true;
    expect(clean.capture(), isNull);
    expect(clean.permits(ticket), isFalse);
    clean.dispose();
    final throwing = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope,
        authSignals: signals, isQuiescent: () => throw StateError('unknown'));
    expect(throwing.capture(), isNull);
    throwing.dispose(); scope.dispose(); signals.dispose(); await events.close();
  });

  test('unchanged session works only in synthetic managed perimeter', () async {
    var session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final signals = ValueNotifier(0);
    final unknown = ReconnectTransitionFenceExperiment(scope: scope, authSignals: signals);
    final managed = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope, authSignals: signals, isQuiescent: () => true);
    expect(unknown.capture(), isNull);
    final ticket = managed.capture()!;
    expect(managed.permits(ticket), isTrue);
    session = fakeSession('a');
    expect(managed.permits(ticket), isTrue);
    managed.dispose(); unknown.dispose(); scope.dispose(); signals.dispose(); await events.close();
  });

  test('app transition cancels claimed ticket synchronously before async work', () async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final signals = ValueNotifier(0);
    final fence = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope, authSignals: signals, isQuiescent: () => true);
    final ticket = fence.capture()!;
    final pending = Completer<void>();
    final action = fence.runAppOwnedTransition(() => pending.future);
    expect(fence.permits(ticket), isFalse);
    expect(fence.capture(), isNull);
    pending.complete(); await action;
    expect(fence.permits(ticket), isFalse);
    expect(fence.capture(), isNull);
    fence.dispose(); scope.dispose(); signals.dispose(); await events.close();
  });

  test('dispatch, delayed auth event and stream error each revoke an existing ticket', () async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast();
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session)); await scope.ready;
    final signals = ValueNotifier(0);
    var fence = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope, authSignals: signals, isQuiescent: () => true);
    var ticket = fence.capture()!;
    signals.value++;
    expect(fence.permits(ticket), isFalse);
    expect(fence.capture(), isNull);
    fence.dispose();
    fence = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope, authSignals: signals, isQuiescent: () => true);
    ticket = fence.capture()!;
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await Future<void>.delayed(Duration.zero);
    expect(fence.permits(ticket), isFalse);
    expect(fence.capture(), isNull);
    fence.dispose();
    fence = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope, authSignals: signals, isQuiescent: () => true);
    ticket = fence.capture()!;
    events.addError(StateError('synthetic offline'));
    await Future<void>.delayed(Duration.zero);
    expect(fence.permits(ticket), isFalse);
    fence.dispose(); scope.dispose(); signals.dispose(); await events.close();
  });

  test('account switch and SDK rotation invalidate; unknown ABA is never admitted', () async {
    var session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final signals = ValueNotifier(0);
    final fence = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope, authSignals: signals, isQuiescent: () => true);
    var ticket = fence.capture()!;
    session = fakeSession('b');
    expect(fence.permits(ticket), isFalse);
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    session = fakeSession('a'); events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(fence.permits(ticket), isFalse);
    fence.dispose();
    final rotatedFence = ReconnectTransitionFenceExperiment.syntheticManaged(scope: scope, authSignals: signals, isQuiescent: () => true);
    ticket = rotatedFence.capture()!;
    session = fakeSession('a', access: 'rotated');
    expect(rotatedFence.permits(ticket), isFalse);
    final unknown = ReconnectTransitionFenceExperiment(scope: scope, authSignals: signals);
    session = fakeSession('b'); session = fakeSession('a', access: 'rotated');
    expect(unknown.capture(), isNull);
    unknown.dispose(); rotatedFence.dispose(); scope.dispose(); signals.dispose(); await events.close();
  });
}
