import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;
import 'forward_outbox_store_test.dart' show Storage;

void main() {
  testWidgets('host is passive and fences old work across source rebind',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final a = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    final b = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    ForwardOutboxStore? current;
    Widget app(AuthSessionScope source, Brightness brightness) => MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: ForwardOutboxHost(
              source: source,
              storage: storage,
              child: Builder(builder: (context) {
                current = ForwardOutboxHost.maybeRead(context);
                return const SizedBox();
              })),
        );
    await tester.pumpWidget(app(a, Brightness.light));
    final old = current!;
    expect(storage.values, isEmpty);
    expect(storage.calls, 0);
    await tester.pumpWidget(app(a, Brightness.dark));
    expect(current, same(old));
    expect(storage.calls, 0);
    events.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    await tester.pump();
    expect(current, same(old));
    await old.put(a.capture()!, 'chat', text: 'before');
    storage.writeEntered = Completer();
    storage.writeRelease = Completer();
    final oldWrite = old.put(a.capture()!, 'chat', text: 'stale');
    await storage.writeEntered!.future;
    await tester.pumpWidget(app(b, Brightness.dark));
    final fresh = current!;
    expect(fresh, isNot(same(old)));
    final freshWrite = fresh.put(b.capture()!, 'chat', text: 'fresh');
    storage.writeEntered = null;
    storage.writeRelease!.complete();
    await expectLater(oldWrite, throwsStateError);
    await freshWrite;
    expect((await fresh.peek(b.capture()!, 'chat'))!.text, 'fresh');
    await expectLater(old.peek(a.capture()!, 'chat'), throwsStateError);
    await tester.pumpWidget(const SizedBox());
    expect(b.capture(), isNotNull);
    a.dispose();
    b.dispose();
    await events.close();
  });
}
