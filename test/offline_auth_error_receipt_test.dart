import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/offline_auth_error_receipt.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'auth_session_scope_test.dart' show fakeSession;

void main() {
  test('receipt uses object identity and immediately revokes on a signal', () {
    final receipt = OfflineAuthErrorReceipt.instance;
    receipt.clear();
    final source = ValueNotifier<int>(0);
    final first = StateError('transport'), sameText = StateError('transport');
    final epoch = source.value;
    var notifications = 0;
    void changed() => notifications++;
    receipt.addListener(changed);
    receipt.install(first, () => source.value == epoch, [source]);
    expect(receipt.accepts(first), isTrue);
    expect(receipt.accepts(sameText), isFalse);
    source.value++;
    expect(receipt.accepts(first), isFalse);
    expect(notifications, 1);
    source.value++;
    expect(notifications, 1);
    receipt.removeListener(changed);
    receipt.clear();
    source.dispose();
  });

  test('capability disposal synchronously revokes an installed receipt', () async {
    final session = fakeSession('a');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(scope.capture()!)!);
    final permit = caps.capture(SessionCapability.cachedRead)!;
    final error = StateError('synthetic');
    final receipt = OfflineAuthErrorReceipt.instance;
    receipt.install(error, () => caps.permits(permit, SessionCapability.cachedRead), [caps]);
    expect(receipt.accepts(error), isTrue);
    caps.dispose();
    expect(receipt.accepts(error), isFalse);
    scope.dispose();
    await events.close();
  });

  test('predicate failures synchronously invalidate existing proof', () {
    final receipt = OfflineAuthErrorReceipt.instance;
    receipt.clear();
    final signal = ValueNotifier<int>(0);
    final error = StateError('synthetic');
    var throws = false, revoked = false;
    void onRevoke() => revoked = true;
    receipt.addListener(onRevoke);
    receipt.install(error, () {
      if (throws) throw StateError('teardown');
      return true;
    }, [signal]);
    expect(receipt.accepts(error), isTrue);
    throws = true;
    expect(receipt.accepts(error), isFalse);
    signal.value++;
    expect(revoked, isTrue);
    expect(receipt.accepts(error), isFalse);
    receipt.removeListener(onRevoke);
    receipt.clear();
    signal.dispose();
  });

  test('listener installation failure leaves no partially active proof', () {
    final receipt = OfflineAuthErrorReceipt.instance;
    receipt.clear();
    final first = ValueNotifier<int>(0);
    final disposed = ValueNotifier<int>(0)..dispose();
    final error = StateError('synthetic');
    receipt.install(error, () => true, [first, disposed]);
    expect(receipt.accepts(error), isFalse);
    expect(first.hasListeners, isFalse);
    first.dispose();
  });

  test('same user new credentials and old error replay cannot revive proof', () async {
    var session = fakeSession('a', access: 'first');
    final events = StreamController<AuthState>.broadcast(sync: true);
    final scope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final owner = scope.capture()!;
    final caps = SessionCapabilities(scope);
    caps.grant(SessionCapabilityMode.cacheOnly, caps.beginAuthorization(owner)!);
    final permit = caps.capture(SessionCapability.cachedRead)!;
    final receipt = OfflineAuthErrorReceipt.instance;
    final error = StateError('old error');
    receipt.install(error, () => scope.isCurrent(owner) &&
      caps.permits(permit, SessionCapability.cachedRead), [scope, caps]);
    expect(receipt.accepts(error), isTrue);
    session = fakeSession('a', access: 'second');
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    expect(receipt.accepts(error), isFalse);
    session = fakeSession('a', access: 'first');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(receipt.accepts(error), isFalse);
    caps.dispose();
    scope.dispose();
    await events.close();
  });
}
