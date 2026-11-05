import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant_host.dart';
import 'package:student_platform/src/core/offline_policy_grant_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _Storage implements OfflineGrantStorage {
  int calls = 0;
  @override
  Future<String?> read(String key) async {
    calls++;
    return null;
  }

  @override
  Future<bool> write(String key, String value) async {
    calls++;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    calls++;
    return true;
  }
}

void main() {
  testWidgets(
      'host is passive, stable across rebuilds and rebinds to new scope',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    Session? readSession() => session;
    final a = AuthSessionScope(
        currentSession: readSession, authEvents: events.stream);
    final b = AuthSessionScope(
        currentSession: readSession, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = _Storage();
    OfflinePolicyGrantAccess? seen;
    Widget build(AuthSessionScope source, Brightness brightness) => MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: OfflinePolicyGrantHost(
              source: source,
              currentSession: readSession,
              issuer: 'https://test.example/auth/v1',
              storage: storage,
              child: Builder(builder: (context) {
                seen = OfflinePolicyGrantHost.maybeRead(context);
                return const SizedBox();
              })),
        );
    await tester.pumpWidget(build(a, Brightness.light));
    final first = seen!;
    expect(first.scope, same(a));
    expect(first.currentBinding(), isNull);
    await tester.pumpWidget(build(a, Brightness.dark));
    expect(seen, same(first));
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    await tester.pump();
    expect(seen, same(first));
    await tester.pumpWidget(build(b, Brightness.dark));
    expect(seen, isNot(same(first)));
    expect(seen!.scope, same(b));
    expect(storage.calls, 0);
    await tester.pumpWidget(const SizedBox());
    a.dispose();
    b.dispose();
    await events.close();
  });
}
