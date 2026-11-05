import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/core/session_capabilities_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

class _ListeningSibling extends StatefulWidget {
  const _ListeningSibling({super.key});
  @override
  State<_ListeningSibling> createState() => _ListeningSiblingState();
}

class _ListeningSiblingState extends State<_ListeningSibling> {
  void changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('production nesting obtains one passive capability host',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    SessionCapabilities? seen;
    await tester.pumpWidget(MaterialApp(
        home: AuthSessionScopeHost(
      createScope: () => scope,
      child: SessionCapabilitiesHost(child: Builder(builder: (context) {
        seen = SessionCapabilitiesHost.maybeOf(context);
        return const SizedBox();
      })),
    )));
    expect(seen, isNotNull);
    expect(seen!.mode, SessionCapabilityMode.blocked);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
  testWidgets('source rebind does not notify sibling during build',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final a = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    final b = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final selected = ValueNotifier<AuthSessionScope>(a);
    final sibling = GlobalKey<_ListeningSiblingState>();
    SessionCapabilities? observed;
    await tester.pumpWidget(MaterialApp(
        home: ValueListenableBuilder<AuthSessionScope>(
      valueListenable: selected,
      builder: (_, source, __) => Column(children: [
        SessionCapabilitiesHost(
            source: source,
            child: Builder(builder: (context) {
              observed = SessionCapabilitiesHost.maybeOf(context);
              return const SizedBox();
            })),
        _ListeningSibling(key: sibling),
      ]),
    )));
    final first = observed!;
    final attempt = first.beginAuthorization(a.capture()!)!;
    first.grant(SessionCapabilityMode.online, attempt);
    first.addListener(sibling.currentState!.changed);
    selected.value = b;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    selected.dispose();
    a.dispose();
    b.dispose();
    await events.close();
  });
  testWidgets('host stays passive, keeps its instance, and rebinds safely',
      (tester) async {
    final eventsA = StreamController<AuthState>.broadcast(sync: true);
    final eventsB = StreamController<AuthState>.broadcast(sync: true);
    var currentA = fakeSession('a');
    final currentB = fakeSession('a');
    final scopeA = AuthSessionScope(
        currentSession: () => currentA, authEvents: eventsA.stream);
    final scopeB = AuthSessionScope(
        currentSession: () => currentB, authEvents: eventsB.stream);
    eventsA.add(AuthState(AuthChangeEvent.initialSession, currentA));
    eventsB.add(AuthState(AuthChangeEvent.initialSession, currentB));
    SessionCapabilities? seen;
    Widget host(AuthSessionScope source, Brightness brightness) => MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: SessionCapabilitiesHost(
              source: source,
              child: Builder(builder: (context) {
                seen = SessionCapabilitiesHost.maybeOf(context);
                return const SizedBox();
              })),
        );
    await tester.pumpWidget(host(scopeA, Brightness.light));
    final first = seen!;
    expect(scopeA.hasListeners, isTrue);
    expect(first.mode, SessionCapabilityMode.blocked);
    await tester.pumpWidget(host(scopeA, Brightness.dark));
    expect(identical(first, seen), isTrue);
    final attempt = first.beginAuthorization(scopeA.capture()!)!;
    expect(first.grant(SessionCapabilityMode.online, attempt), isTrue);
    final permit = first.capture(SessionCapability.mutation)!;
    currentA = fakeSession('b');
    eventsA.add(AuthState(AuthChangeEvent.signedIn, currentA));
    await tester.pump();
    expect(identical(first, seen), isTrue);
    expect(first.permits(permit, SessionCapability.mutation), isFalse);
    expect(first.mode, SessionCapabilityMode.blocked);
    await tester.pumpWidget(host(scopeB, Brightness.dark));
    expect(identical(first, seen), isFalse);
    expect(seen!.mode, SessionCapabilityMode.blocked);
    expect(first.capture(SessionCapability.cachedRead), isNull);
    expect(scopeA.hasListeners, isFalse);
    expect(scopeB.hasListeners, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(scopeB.hasListeners, isFalse);
    scopeA.dispose();
    scopeB.dispose();
    await eventsA.close();
    await eventsB.close();
  });
}
