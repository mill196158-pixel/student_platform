import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/services/push/chat_read_progress.dart';
import 'support/scoped_draft_test_session.dart';

void main() {
  testWidgets('an open chat leaves incoming messages unread in the background', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    await tester.runAsync(() async {
      await Supabase.initialize(url: 'https://example.invalid', publishableKey: 'fixture',
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false));
      await signInForScopedDraft(Supabase.instance.client);
    });
    addTearDown(() async {
      await Supabase.instance.dispose();
      messenger.setMockMethodCallHandler(links, null);
    });
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final context = tester.element(find.byType(SizedBox));
    final owner = captureChatReadOwner(context)!;
    final writes = <String>[];
    final progress = ChatReadProgress();
    Future<void> mark(String id) => progress.mark(
      scope: owner.session, messageId: id, current: owner.current,
      markCursor: () async { writes.add('cursor $id'); },
      syncNotifications: () async { writes.add('read $id'); },
    );
    await mark('one');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(captureChatReadOwner(context), isNull);
    await mark('two');
    expect(writes, ['cursor one', 'read one']);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await mark('two');
    expect(writes, ['cursor one', 'read one', 'cursor two', 'read two']);
  });

  test(
      'partial read retries just the notifications, with one retry then a later resume',
      () async {
    final read = ChatReadProgress(retryDelay: Duration.zero);
    var cursor = 0, notifications = 0;
    Future<void> mark() => read.mark(
        scope: 'session/chat',
        messageId: 'message',
        current: () => true,
        markCursor: () async {
          cursor++;
        },
        syncNotifications: () async {
          if (++notifications <= 2) throw StateError('offline');
        });
    await expectLater(mark(), throwsStateError);
    expect((cursor, notifications), (1, 2));
    await mark();
    await mark();
    expect((cursor, notifications), (1, 3));
  });

  test(
      'concurrent events coalesce, revocation during the first attempt prevents retry',
      () async {
    final read = ChatReadProgress(retryDelay: Duration.zero);
    var cursor = 0, notifications = 0;
    var current = true;
    final pending = Completer<void>();
    Future<void> mark() => read.mark(
        scope: 'session/chat',
        messageId: 'message',
        current: () => current,
        markCursor: () async {
          cursor++;
        },
        syncNotifications: () async {
          notifications++;
          await pending.future;
        });
    final first = mark(), second = mark();
    await Future<void>.delayed(Duration.zero);
    expect((cursor, notifications), (1, 1));
    current = false;
    pending.completeError(StateError('offline'));
    await Future.wait([first, second]);
    expect((cursor, notifications), (1, 1));
  });
}
