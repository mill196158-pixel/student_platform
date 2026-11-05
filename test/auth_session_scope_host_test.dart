import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('host keeps one scope through rebuilds and disposes it',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = Session(
        accessToken: 'token',
        tokenType: 'bearer',
        user: const User(
            id: 'a',
            appMetadata: {},
            userMetadata: null,
            aud: '',
            createdAt: ''));
    var created = 0;
    late AuthSessionScope source;
    AuthSessionScope create() {
      created++;
      return source = AuthSessionScope(
          currentSession: () => current, authEvents: events.stream);
    }

    Widget buildHost(ThemeData theme) => MaterialApp(
        theme: theme,
        home: AuthSessionScopeHost(
            createScope: create,
            child: Builder(builder: (context) {
              final scope = AuthSessionScopeHost.maybeOf(context)!;
              return Text('${scope.generation}',
                  textDirection: TextDirection.ltr);
            })));
    await tester.pumpWidget(buildHost(ThemeData.light()));
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    await tester.pump();
    final original = source.capture()!;
    await tester.pumpWidget(buildHost(ThemeData.dark()));
    expect(created, 1);
    expect(source.isCurrent(original), isTrue);
    source.invalidateForSignOut();
    await tester.pump();
    expect(source.isCurrent(original), isFalse);
    expect(find.text('1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(source.capture(), isNull);
    expect(events.hasListener, isFalse);
    await events.close();
  });
}
