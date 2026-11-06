import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/forward_author_label.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;

Message source(
        {String chat = 'source',
        String id = 'message',
        String author = 'author'}) =>
    Message(
      id: id,
      chatId: chat,
      authorId: author,
      authorLogin: '',
      authorName: 'Real name',
      text: '',
      at: DateTime.utc(2026),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('initial auth event may arrive after the forward is mounted',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final current = fakeSession('owner');
    final scope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    await tester.pumpWidget(MaterialApp(
        home: AuthSessionScopeHost(
            createScope: () => scope,
            child: ForwardAuthorLabel(
                originalChatId: 'source',
                messageId: 'message',
                authorId: 'author',
                storedName: 'Студент',
                debugLoader: ({required chatId, required messageId}) async =>
                    source(),
                builder: (_, name) => Text(name)))));
    expect(find.text('Студент'), findsOneWidget);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    await tester.pumpAndSettle();
    expect(find.text('Real name'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
  testWidgets(
      'only exact authorized original restores a generic forward author',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var current = fakeSession('owner');
    final scope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final pending = Completer<Message?>();
    await tester.pumpWidget(MaterialApp(
        home: AuthSessionScopeHost(
            createScope: () => scope,
            child: ForwardAuthorLabel(
                originalChatId: 'source',
                messageId: 'message',
                authorId: 'author',
                storedName: 'Студент',
                debugLoader: ({required chatId, required messageId}) =>
                    pending.future,
                builder: (_, name) => Text(name)))));
    await tester.pump();
    expect(find.text('Студент'), findsOneWidget);
    pending.complete(source());
    await tester.pumpAndSettle();
    expect(find.text('Real name'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  for (final mismatch in ['chat', 'message', 'author', 'denied']) {
    testWidgets(
        'does not reveal author for mismatched or unreadable original: $mismatch',
        (tester) async {
      final events = StreamController<AuthState>.broadcast(sync: true);
      final current = fakeSession('owner');
      final scope = AuthSessionScope(
          currentSession: () => current, authEvents: events.stream);
      events.add(AuthState(AuthChangeEvent.initialSession, current));
      await tester.pumpWidget(MaterialApp(
          home: AuthSessionScopeHost(
              createScope: () => scope,
              child: ForwardAuthorLabel(
                  originalChatId: 'source',
                  messageId: 'message',
                  authorId: 'author',
                  storedName: 'Студент',
                  debugLoader: ({required chatId, required messageId}) async {
                    if (mismatch == 'denied')
                      throw StateError('not authorized');
                    return source(
                        chat: mismatch == 'chat' ? 'other' : 'source',
                        id: mismatch == 'message' ? 'other' : 'message',
                        author: mismatch == 'author' ? 'other' : 'author');
                  },
                  builder: (_, name) => Text(name)))));
      await tester.pumpAndSettle();
      expect(find.text('Студент'), findsOneWidget);
      expect(find.text('Real name'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    });
  }

  testWidgets('late result from a previous account is never displayed',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var current = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => current, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, current));
    final first = Completer<Message?>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
        home: AuthSessionScopeHost(
            createScope: () => scope,
            child: ForwardAuthorLabel(
                originalChatId: 'source',
                messageId: 'message',
                authorId: 'author',
                storedName: 'Студент',
                debugLoader: ({required chatId, required messageId}) {
                  calls++;
                  return calls == 1 ? first.future : Future.value(null);
                },
                builder: (_, name) => Text(name)))));
    await tester.pump();
    current = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, current));
    await tester.pump();
    first.complete(source());
    await tester.pumpAndSettle();
    expect(find.text('Студент'), findsOneWidget);
    expect(find.text('Real name'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
