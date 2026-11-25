import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/core/chat_message_cache_store.dart';
import 'package:student_platform/src/ui/chats/data/dm_api.dart';
import 'package:student_platform/src/ui/chats/direct_chat_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _origin = 'http://127.0.0.1:55321';

class _LocalSockets extends HttpOverrides {}

class _LocalTransport extends http.BaseClient {
  final inner = IOClient(
      _LocalSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final releaseFirst = Completer<void>();
  final firstCommitted = Completer<void>();
  int sends = 0;
  bool offlineSend = false;
  bool loseAcknowledgement = false;
  var offlineAttempt = Completer<void>();
  var failOfflineAttempt = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _origin)
      throw StateError('Local test service required');
    final isSend = request.url.path.endsWith('/rpc/send_dm_message_once');
    final delay = isSend && ++sends == 1;
    if (isSend && offlineSend) {
      offlineAttempt.complete();
      await failOfflineAttempt.future;
      throw const SocketException('Test delivery interrupted');
    }
    final response = await inner.send(request);
    if (isSend && loseAcknowledgement && response.statusCode == 200) {
      loseAcknowledgement = false;
      await response.stream.drain<void>();
      throw const SocketException('Test acknowledgement interrupted');
    }
    if (!delay || response.statusCode != 200) return response;
    final data = await response.stream.toBytes();
    firstCommitted.complete();
    await releaseFirst.future;
    return http.StreamedResponse(Stream.value(data), response.statusCode,
        headers: response.headers, request: request);
  }

  @override
  void close() => inner.close();
}

void main() {
  final configs = Platform.environment['STUDENT_ORDINARY_DM_CONFIGS'];
  if (configs != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets(
      'two students exchange, quote and edit a direct message through the composer',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final paths = (jsonDecode(configs!) as List).cast<String>();
      final accounts = [
        for (final p in paths) jsonDecode(File(p).readAsStringSync()) as Map
      ];
      if (SupabaseConfig.url != _origin) {
        throw StateError(
            'Use --dart-define=SUPABASE_URL=$_origin for the local session issuer');
      }
      if (accounts.length != 2 ||
          accounts.any((a) =>
              a['port'] != 55321 ||
              !(a['login'] as String).startsWith('e2e_')) ||
          accounts[0]['recipientId'] == accounts[1]['recipientId']) {
        throw StateError('Two distinct local test students required');
      }
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/events'),
          (_) async => null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('keyboard_image_channel'), (_) async => null);
      await initializeDateFormatting('ru');
      final transport = _LocalTransport();
      await Supabase.initialize(
          url: _origin,
          publishableKey: accounts.first['anonKey'],
          httpClient: transport,
          authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false, detectSessionInUri: false));
      final me = Supabase.instance.client;
      final peer = SupabaseClient(_origin, accounts.last['anonKey']);
      try {
        for (final (client, account) in [
          (me, accounts.first),
          (peer, accounts.last)
        ]) {
          final login = await client.auth.signInWithPassword(
              email: account['email'], password: account['password']);
          expect(login.user?.id, account['recipientId']);
        }
        final peerId = peer.auth.currentUser!.id;
        final chat = await me
            .rpc('ensure_dm_chat', params: {'p_partner': peerId}) as String;
        final tag = Platform.environment['STUDENT_DM_MARKER'] ??
            DateTime.now().microsecondsSinceEpoch.toString();
        final first = 'Исходящее $tag',
            incoming = 'Входящее $tag',
            quote = 'Ответ $tag',
            edited = 'Правка $tag';
        await ChatMessageCacheStore.initializeCurrentUser();
        Future<List<Map<String, dynamic>>> page() async => (await peer
                    .rpc('get_chat_messages_page', params: {'p_chat_id': chat})
                as List)
            .cast<Map<String, dynamic>>();
        Future<void> until(
            FutureOr<bool> Function() condition, String checkpoint) async {
          final deadline = DateTime.now().add(const Duration(seconds: 18));
          while (DateTime.now().isBefore(deadline)) {
            if (await condition()) return;
            await tester.pump(const Duration(milliseconds: 65));
          }
          fail(checkpoint);
        }

        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(AuthSessionScopeHost(
            child: MaterialApp(
                theme: AppTheme.light().data,
                home: Scaffold(
                    body: Builder(
                        builder: (context) => TextButton(
                            onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) => DirectChatScreen(
                                        peerId: peerId,
                                        peerName: 'Тестовый собеседник',
                                        initialChatId: chat))),
                            child: const Text('Переписка')))))));
        final field = find.byType(EditableText);
        final send = find.byTooltip('Отправить');
        Future<void> open() async {
          await tester.tap(find.text('Переписка'));
          await until(() => field.evaluate().isNotEmpty,
              'The ordinary DM composer did not open');
          await tester.pump(const Duration(milliseconds: 350));
        }

        Future<void> closeChat() async {
          await tester.binding.handlePopRoute();
          await until(
              () =>
                  find
                      .byType(DirectChatScreen, skipOffstage: false)
                      .evaluate()
                      .isEmpty &&
                  find.text('Переписка').hitTestable().evaluate().isNotEmpty,
              'Chat did not close');
        }

        Future<void> type(String text) async {
          await until(
              () =>
                  field.hitTestable().evaluate().isNotEmpty &&
                  send.hitTestable().evaluate().isNotEmpty,
              'Composer is not ready for input');
          await tester.enterText(field, text);
          await tester.tap(send);
        }

        Future<void> action(String messageId, String text, String name) async {
          final row = find.byKey(ValueKey('message-$messageId'));
          final bubble = find.descendant(of: row, matching: find.text(text));
          await until(() => bubble.evaluate().isNotEmpty,
              'The confirmed message did not render');
          await tester.ensureVisible(bubble);
          await tester.longPress(bubble);
          await until(() => find.text(name).hitTestable().evaluate().isNotEmpty,
              'Message action missing: $name');
          await tester.tap(find.text(name).hitTestable().last);
          await tester.pump(const Duration(milliseconds: 350));
        }

        await open();
        await type(first);
        await until(() => transport.firstCommitted.isCompleted,
            'The first send was not acknowledged by PostgREST');
        await tester.tap(send);
        expect((await page()).where((r) => r['text'] == first), hasLength(1));
        transport.releaseFirst.complete();
        await until(() => find.text(first).hitTestable().evaluate().isNotEmpty,
            'Sender did not render the sent message');
        expect(transport.sends, 1);
        final incomingId = await peer.rpc('send_dm_message_once', params: {
          'p_chat_id': chat,
          'p_client_key': 'qa-peer-$tag',
          'p_text': incoming
        });
        await until(
            () => find.text(incoming).hitTestable().evaluate().isNotEmpty,
            'Peer message did not arrive in the open conversation');
        await until(() async {
          final notices = await me
              .rpc('get_my_app_notifications', params: {'p_limit': 50}) as List;
          return notices.any((row) =>
              row['data']['message_id'] == incomingId &&
              row['read_at'] != null);
        }, 'A visible incoming message kept an unread notification');
        await action(incomingId as String, incoming, 'Ответить');
        await type(quote);
        await until(
            () async => (await page()).any((r) =>
                r['text'] == quote &&
                r['reply_to_id'] == incomingId &&
                r['author_id'] == me.auth.currentUser?.id),
            'The quote was not stored with its parent');
        await until(() => find.text(quote).hitTestable().evaluate().isNotEmpty,
            'Quoted message did not appear');
        final replyId = (await page())
            .singleWhere((row) => row['text'] == quote)['id'] as String;
        await action(replyId, quote, 'Изменить');
        await until(() => find.text('Редактирование').evaluate().isNotEmpty,
            'Inline editing did not open');
        await type(edited);
        await until(
            () async => (await page()).any((r) =>
                r['text'] == edited &&
                r['edited_at'] != null &&
                r['reply_to_id'] == incomingId),
            'The edit was not persisted');
        await closeChat();
        await open();
        await until(
            () =>
                find.text(edited).evaluate().isNotEmpty &&
                find.text(first).evaluate().isNotEmpty,
            'Reopened conversation did not restore the edited history');
        final saved = await page();
        expect(
            saved.where((r) => [first, incoming, edited].contains(r['text'])),
            hasLength(3));
        expect(saved.where((r) => r['text'] == quote), isEmpty);
        final lost = 'Повтор $tag';
        transport.offlineSend = true;
        await type(lost);
        await until(() => transport.offlineAttempt.isCompleted,
            'Offline send was not attempted');
        final nextDraft = 'Следующее сообщение $tag';
        await tester.enterText(field, nextDraft);
        transport.failOfflineAttempt.complete();
        final retry = find.text('Повторить').hitTestable();
        await until(() => retry.evaluate().isNotEmpty,
            'Offline message missing a retry action');
        expect((await page()).where((r) => r['text'] == lost), isEmpty);
        transport.offlineSend = false;
        transport.loseAcknowledgement = true;
        await tester.tap(retry);
        await until(
            () async =>
                !transport.loseAcknowledgement &&
                (await page()).any((r) => r['text'] == lost) &&
                retry.evaluate().isNotEmpty,
            'The chat lost its pending message after a missing acknowledgement');
        await tester.tap(retry);
        await until(
            () =>
                retry.evaluate().isEmpty &&
                find.text(lost).evaluate().length == 1,
            'Acknowledged retry was not reconciled in the chat');
        expect((await page()).where((r) => r['text'] == lost), hasLength(1));
        expect(tester.widget<EditableText>(field).controller.text, nextDraft);
        final sendError =
            find.text('Отправка не подтверждена. Проверьте сообщение в чате.');
        await until(() => sendError.evaluate().isEmpty,
            'Earlier send feedback did not dismiss');
        final departed = 'После возврата $tag';
        transport.offlineAttempt = Completer<void>();
        transport.failOfflineAttempt = Completer<void>();
        transport.offlineSend = true;
        await type(departed);
        await until(() => transport.offlineAttempt.isCompleted,
            'Closing scenario did not start a send');
        await closeChat();
        transport.offlineSend = false;
        transport.failOfflineAttempt.complete();
        await tester.pump(const Duration(milliseconds: 250));
        expect(sendError, findsNothing);
        await open();
        await until(() => retry.evaluate().isNotEmpty,
            'Pending send unavailable after leaving the conversation');
        await tester.tap(retry);
        await until(
            () async =>
                (await page()).where((r) => r['text'] == departed).length ==
                    1 &&
                retry.evaluate().isEmpty,
            'Retry failed after reopening the conversation');
        expect(tester.takeException(), isNull);
      } finally {
        if (!transport.releaseFirst.isCompleted)
          transport.releaseFirst.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await DmApi.clearSessionState();
        await peer.dispose();
        await Supabase.instance.dispose();
        transport.close();
      }
    }, _LocalSockets());
  }, skip: configs == null);
}
