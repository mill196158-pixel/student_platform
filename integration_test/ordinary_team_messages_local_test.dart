import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = 'https://127.0.0.1:55443';

class _Acknowledgement {
  final committed = Completer<void>();
  final release = Completer<void>();
}

class _ObserveClosedChat extends BlocObserver {
  final errors = <Object>[];
  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    if (bloc is TeamCubit && bloc.isClosed) errors.add(error);
    super.onError(bloc, error, stackTrace);
  }
}

class _HoldSendResponse extends http.BaseClient {
  final inner = IOClient(HttpClient()..findProxy = (_) => 'DIRECT');
  var pending = _Acknowledgement();
  bool interruptHydration = false;
  int interruptedReads = 0;
  int sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _url) throw StateError('Expected local backend');
    if (interruptHydration &&
        request.method == 'GET' &&
        request.url.path == '/rest/v1/messages' &&
        request.url.queryParameters.containsKey('id')) {
      interruptedReads++;
      return http.StreamedResponse(
          Stream.value(utf8
              .encode('{"message":"Temporary detail outage","code":"503"}')),
          503,
          request: request,
          headers: {'content-type': 'application/json'});
    }
    final sending = request.url.path.endsWith('/send_chat_message');
    if (sending) sends++;
    final response = await inner.send(request);
    final acknowledgement = pending;
    if (sending &&
        !acknowledgement.committed.isCompleted &&
        response.statusCode == 200) {
      acknowledgement.committed.complete();
      await acknowledgement.release.future;
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final paths = Platform.environment['STUDENT_CHAT_SWITCH_CONFIGS'];
  final manifest = Platform.environment['STUDENT_CHAT_SWITCH_MANIFEST'];
  testWidgets(
      'send once, receive a live team reply and reopen the conversation',
      (tester) async {
    final configs = [
      for (final path in jsonDecode(paths!) as List)
        jsonDecode(File(path as String).readAsStringSync()) as Map
    ];
    final group =
        (jsonDecode(File(manifest!).readAsStringSync()) as List).single;
    final team = group['team'] as String;
    final chat = group['chat'] as String;
    expect(SupabaseConfig.url, _url);
    final certificate = File(Platform.environment['STUDENT_TEAM_LOCAL_CA']!);
    SecurityContext.defaultContext
        .setTrustedCertificatesBytes(await certificate.readAsBytes());
    final client = _HoldSendResponse();
    final oldObserver = Bloc.observer;
    final observer = _ObserveClosedChat();
    Bloc.observer = observer;
    tester.testTextInput.register();
    SharedPreferences.setMockInitialValues({});
    await initializeDateFormatting('ru');
    await Supabase.initialize(
        url: _url,
        publishableKey: configs.first['anonKey'],
        httpClient: client,
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage()));
    final me = Supabase.instance.client;
    final peer = SupabaseClient(_url, configs.last['anonKey']);
    try {
      for (final (sdk, config) in [(me, configs.first), (peer, configs.last)]) {
        final auth = await sdk.auth.signInWithPassword(
            email: config['email'], password: config['password']);
        expect(auth.user?.id == config['recipientId'], isTrue);
      }
      final initial = 'QA meeting ${team.substring(0, 8)}';
      final outgoing = 'Я буду на встрече ${team.substring(0, 8)}';
      final incoming = 'Договорились ${team.substring(0, 8)}';
      final nextDraft = 'Черновик следующего сообщения';
      Future<String> peerSend(String content, {String? replyTo}) async =>
          await peer.rpc('send_chat_message', params: {
            'p_team_id': team,
            'p_text': content,
            if (replyTo != null) 'p_reply_to': replyTo,
          }) as String;
      Future<List> history() async =>
          await peer.rpc('get_chat_messages_page', params: {'p_chat_id': chat})
              as List;
      await peerSend(initial);
      await tester.pumpWidget(
          const AuthSessionScopeHost(child: SizedBox(key: Key('session'))));
      await AuthSessionScopeHost.maybeRead(
              tester.element(find.byKey(const Key('session'))))!
          .ready;
      await tester.pumpWidget(AuthSessionScopeHost(
          child: MaterialApp(
              theme: AppTheme.light().data, home: const MyChatsScreen())));
      Future<void> wait(bool Function() done, String reason) async {
        final end = DateTime.now().add(const Duration(seconds: 24));
        while (!done() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(done(), isTrue, reason: reason);
      }

      final row = find.byKey(ValueKey(chat));
      final screen = find.byType(TeamDetailsScreen);
      final composer =
          find.descendant(of: screen, matching: find.byType(EditableText));
      Future<void> open() async {
        await wait(() => row.evaluate().isNotEmpty, 'Chat list');
        await tester.ensureVisible(row);
        await tester.tap(row);
        await wait(
            () =>
                find.byType(TeamDetailsScreen).evaluate().isNotEmpty &&
                find
                    .descendant(of: screen, matching: find.text(initial))
                    .evaluate()
                    .isNotEmpty &&
                composer.evaluate().length == 1,
            'Initial history');
      }

      await open();
      await tester.enterText(composer, outgoing);
      await tester.pump();
      final send =
          find.descendant(of: screen, matching: find.byTooltip('Отправить'));
      await tester.tap(send);
      await tester.tap(send);
      await wait(() => client.pending.committed.isCompleted,
          'Backend did not confirm send');
      await tester.tap(composer);
      await tester.pump();
      await tester.enterText(composer, nextDraft);
      await tester.pump();
      expect(tester.widget<EditableText>(composer).controller.text, nextDraft,
          reason: 'Typing before confirmation');
      client.pending.release.complete();
      await wait(
          () => find.text(outgoing).evaluate().isNotEmpty, 'Sent message');
      final sent = (await history()).where((r) => r['text'] == outgoing).single;
      expect(sent['author_id'], me.auth.currentUser!.id);
      expect(client.sends, 1);
      final reply = await peerSend(incoming, replyTo: sent['id'] as String);
      await wait(() => find.text(incoming).evaluate().isNotEmpty,
          'Reply in the open conversation');
      expect(tester.widget<EditableText>(composer).controller.text, nextDraft);
      await tester.tap(find.byTooltip('Назад'));
      await tester.pump(const Duration(milliseconds: 500));
      await open();
      await wait(
          () => find.text(incoming).evaluate().isNotEmpty, 'Restored reply');
      final page = await history();
      expect(page.where((r) => r['text'] == outgoing), hasLength(1));
      expect(page.where((r) => r['id'] == reply).single['reply_to_id'],
          sent['id']);
      expect(page.where((r) => r['text'] == nextDraft), isEmpty);

      final lateSend = 'Отправлено перед выходом ${team.substring(0, 8)}';
      final lastDraft = 'Продолжу после возврата ${team.substring(0, 8)}';
      final oldChat = tester.element(composer).read<TeamCubit>();
      client.pending = _Acknowledgement();
      await tester.tap(composer);
      await tester.enterText(composer, lateSend);
      await tester.pump();
      await tester.tap(send);
      await wait(() => client.pending.committed.isCompleted,
          'Second send did not reach the server before leaving');
      await tester.tap(composer);
      await tester.enterText(composer, lastDraft);
      await tester.pump();
      expect(tester.widget<EditableText>(composer).controller.text, lastDraft);
      await tester.tap(find.byTooltip('Назад'));
      await wait(
          () => oldChat.isClosed && row.hitTestable().evaluate().isNotEmpty,
          'The old conversation did not close before the response');
      client.pending.release.complete();
      await open();
      await wait(() => find.text(lateSend).evaluate().isNotEmpty,
          'Acknowledged message is missing after reopening');
      await wait(
          () =>
              tester.widget<EditableText>(composer).controller.text ==
              lastDraft,
          'Next draft was lost when leaving during send');
      final afterLeave = await history();
      expect(afterLeave.where((r) => r['text'] == lateSend), hasLength(1));
      expect(afterLeave.where((r) => r['text'] == lastDraft), isEmpty);
      expect(client.sends, 2);
      // The UI action has a void callback. Exercise its real sender separately
      // to await the whole operation, including hydration after the server reply.
      final acknowledgedText =
          'Подтверждение после выхода ${team.substring(0, 8)}';
      final sender = tester.element(composer).read<TeamCubit>();
      client.pending = _Acknowledgement();
      final sendResult = sender.sendMessage('me', acknowledgedText);
      await wait(() => client.pending.committed.isCompleted,
          'Final send did not commit');
      await tester.tap(find.byTooltip('Назад'));
      await wait(() => sender.isClosed, 'Sender is still open');
      final beforeRefresh = me.auth.currentSession!;
      final refreshed = await me.auth.refreshSession();
      expect(refreshed.user?.id, beforeRefresh.user.id);
      expect(
          refreshed.session!.accessToken == beforeRefresh.accessToken, isFalse);
      client.pending.release.complete();
      final acknowledgedId = await sendResult;
      final persisted =
          (await history()).where((r) => r['text'] == acknowledgedText).single;
      expect(acknowledgedId, persisted['id']);
      expect(client.sends, 3);

      // Isolate acknowledgement from Realtime. The detail read fails after
      // the real server write; the row must already have its confirmed ID.
      final withoutRealtime = TeamCubit(sender.state.team);
      try {
        final text = 'Без повторной отправки ${team.substring(0, 8)}';
        client.interruptHydration = true;
        final result = await withoutRealtime.sendMessage('me', text);
        client.interruptHydration = false;
        expect(client.interruptedReads, greaterThan(0));
        final stored = (await history()).where((r) => r['text'] == text).single;
        final bubble =
            withoutRealtime.state.chat.where((m) => m.text == text).single;
        expect(result, stored['id']);
        expect(bubble.id, stored['id'],
            reason: 'A confirmed message must leave its pending state');
        expect(bubble.isLocal || bubble.isSending || bubble.isFailed, isFalse);
        expect(client.sends, 4);
      } finally {
        client.interruptHydration = false;
        await withoutRealtime.close();
      }
      expect(observer.errors, isEmpty,
          reason: 'Late send updated a closed conversation');
      expect(tester.takeException(), isNull);
    } finally {
      if (!client.pending.release.isCompleted)
        client.pending.release.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await peer.dispose();
      await Supabase.instance.dispose();
      client.close();
      tester.testTextInput.unregister();
      Bloc.observer = oldObserver;
    }
  }, skip: paths == null || manifest == null);
}
