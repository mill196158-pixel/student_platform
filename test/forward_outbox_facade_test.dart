import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:student_platform/src/ui/chats/forward/forward_session_guard.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth_session_scope_test.dart' show fakeSession;
import 'forward_outbox_store_test.dart' show Storage;

void main() {
  test('picker guard prevents dispatch for a changed session', () async {
    var calls = 0;
    expect(
        await resolveForwardTargetForSession(() => false, () async {
          calls++;
          return 'chat';
        }),
        isNull);
    expect(calls, 0);
    var current = true;
    final delayed = Completer<String>();
    final pending =
        resolveForwardTargetForSession(() => current, () => delayed.future);
    current = false;
    delayed.complete('chat');
    expect(await pending, isNull);
  });

  test('selection and composer survive failed handoff', () async {
    var selection = true;
    var text = 'draft';
    await expectLater(
        completeForwardHandoff(
            prepare: () async => throw const ForwardOutboxStorageFailure(),
            isCurrent: () => true,
            onPrepared: () {
              selection = false;
              text = '';
            }),
        throwsA(isA<ForwardOutboxStorageFailure>()));
    expect(selection, isTrue);
    expect(text, 'draft');
  });
  testWidgets('facade coordinates writes and legacy-compatible take',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    var session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    late ForwardOutboxSession captured;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: storage,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    await expectLater(captured.putForChat(chatId: '   ', text: 'missing'),
        throwsFormatException);
    expect(await captured.tryTakeForChat(' '), isNull);
    expect(storage.calls, 0);
    await captured.putForChat(chatId: 'chat', text: 'saved');
    final data = await captured.tryTakeForChat('chat');
    expect(data?.text, 'saved');
    expect(data?.fileUrls, isEmpty);
    expect(await captured.tryTakeForChat('chat'), isNull);
    await captured.putForChat(chatId: 'chat', text: 'old');
    storage.failures.add('write-false');
    await expectLater(captured.putForChat(chatId: 'chat', text: 'new'),
        throwsA(isA<ForwardOutboxStorageFailure>()));
    expect((await captured.tryTakeForChat('chat'))?.text, 'old');
    session = fakeSession('b');
    events.add(AuthState(AuthChangeEvent.signedIn, session));
    expect(captured.isCurrent, isFalse);
    await expectLater(
        captured.putForChat(chatId: 'chat', text: 'wrong account'),
        throwsStateError);
    expect(await captured.tryTakeForChat('chat'), isNull);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });

  testWidgets('plain legacy text with unbound files remains stored',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    late ForwardOutboxSession captured;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: storage,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    await captured
        .putForChat(chatId: 'chat', text: 'legacy', fileUrls: ['file']);
    final before = storage.values['forward_outbox_a_chat'];
    await expectLater(captured.tryTakeForChat('chat'), throwsFormatException);
    expect(storage.values['forward_outbox_a_chat'], before);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });
  testWidgets('ID-only payload remains in outbox on failed validation',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    late ForwardOutboxSession captured;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: storage,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    final payload = ForwardPayload(fromChatId: 'source', items: [
      ForwardItem(
          messageId: 'm',
          authorId: 'a',
          authorName: 'A',
          at: DateTime.utc(2026),
          text: '',
          files: [])
    ]);
    await captured.putForChat(
        chatId: 'chat', text: payload.encodeForText(), fileIds: ['file-id']);
    final before = storage.values['forward_outbox_a_chat'];
    await expectLater(captured.tryTakeForChat('chat'), throwsFormatException);
    expect(storage.values['forward_outbox_a_chat'], before);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });
  testWidgets('rebind during take never returns old data to new host',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final a = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    final b = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    late ForwardOutboxSession captured;
    Widget app(AuthSessionScope source) => MaterialApp(
        home: ForwardOutboxHost(
            source: source,
            storage: storage,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            })));
    await tester.pumpWidget(app(a));
    final old = captured;
    await old.putForChat(chatId: 'chat', text: 'saved');
    storage.removeEntered = Completer();
    storage.removeRelease = Completer();
    final pending = old.tryTakeForChat('chat');
    await storage.removeEntered!.future;
    await tester.pumpWidget(app(b));
    storage.removeEntered = null;
    storage.removeRelease!.complete();
    await expectLater(pending, throwsStateError);
    expect(storage.values.values.single, contains('saved'));
    expect(captured.isCurrent, isTrue);
    await tester.pumpWidget(const SizedBox());
    a.dispose();
    b.dispose();
    await events.close();
  });

  testWidgets('take cannot delete a replacement queued during peek',
      (tester) async {
    final events = StreamController<AuthState>.broadcast(sync: true);
    final session = fakeSession('a');
    final scope = AuthSessionScope(
        currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final storage = Storage();
    late ForwardOutboxSession captured;
    await tester.pumpWidget(MaterialApp(
        home: ForwardOutboxHost(
            source: scope,
            storage: storage,
            child: Builder(builder: (context) {
              captured = ForwardOutbox.capture(context)!;
              return const SizedBox();
            }))));
    await captured.putForChat(chatId: 'chat', text: 'old');
    storage.readEntered = Completer();
    storage.readRelease = Completer();
    final take = captured.tryTakeForChat('chat');
    await storage.readEntered!.future;
    final replacement = captured.putForChat(chatId: 'chat', text: 'new');
    storage.readEntered = null;
    storage.readRelease!.complete();
    await replacement;
    // The outer coordinator now serializes the complete take before the new
    // writer, so the old value is delivered and the replacement remains.
    expect((await take)?.text, 'old');
    expect((await captured.tryTakeForChat('chat'))?.text, 'new');
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await events.close();
  });
}
