import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _LocalSockets extends HttpOverrides {}

void main() {
  final paths = Platform.environment['STUDENT_CHAT_SWITCH_CONFIGS'];
  final manifest = Platform.environment['STUDENT_CHAT_SWITCH_MANIFEST'];
  final enabled = paths != null && manifest != null;
  if (enabled) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }

  testWidgets('organize two conversations through the student message list',
      (tester) async {
    const url = 'http://127.0.0.1:55321';
    final accounts = [
      for (final path in jsonDecode(paths!) as List)
        jsonDecode(File(path).readAsStringSync()) as Map,
    ];
    final groups = jsonDecode(File(manifest!).readAsStringSync()) as List;
    expect(accounts.length, 3);
    expect(groups.length, 2);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/events'),
            (_) async => null);
    await initializeDateFormatting('ru');
    final transport = IOClient(
        _LocalSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
    await Supabase.initialize(
        url: url,
        publishableKey: accounts.first['anonKey'],
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(
            detectSessionInUri: false, autoRefreshToken: false));
    final owner = Supabase.instance.client;
    final peers = [
      for (final account in accounts.skip(1))
        SupabaseClient(url, account['anonKey'],
            httpClient: transport,
            authOptions: const AuthClientOptions(autoRefreshToken: false))
    ];

    final clients = [owner, ...peers];
    try {
      for (var i = 0; i < clients.length; i++) {
        final result = await clients[i].auth.signInWithPassword(
            email: accounts[i]['email'], password: accounts[i]['password']);
        expect(result.user?.id, accounts[i]['recipientId']);
      }
      String chat(int i) => groups[i]['chat'] as String;
      Finder row(int i) => find.byKey(ValueKey(chat(i)));
      Finder inRow(int i, Finder what) =>
          find.descendant(of: row(i), matching: what);
      Future<String> send(int i, String message) async =>
          await peers[i].rpc('send_chat_message',
                  params: {'p_team_id': groups[i]['team'], 'p_text': message})
              as String;
      Future<Map> summary(int i) async {
        final all = await owner.rpc('get_my_chat_summaries') as List;
        return all.singleWhere((r) => r['chat_id'] == chat(i)) as Map;
      }

      Future<List> notices() async =>
          await owner.rpc('get_my_app_notifications', params: {'p_limit': 50})
              as List;
      bool forMessage(dynamic notice, String id) =>
          notice['data']['message_id'] == id;
      Future<void> until(
          Future<bool> Function() condition, String failure) async {
        for (int i = 0; i < 100; i++) {
          if (await condition()) return;
          await tester.pump(const Duration(milliseconds: 70));
        }
        fail(failure);
      }

      Future<void> list() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
            const AuthSessionScopeHost(child: SizedBox(key: Key('ready'))));
        await AuthSessionScopeHost.maybeRead(
                tester.element(find.byKey(const Key('ready'))))!
            .ready;
        await tester.pumpWidget(AuthSessionScopeHost(
            child: MaterialApp(
                theme: AppTheme.light().data, home: const MyChatsScreen())));
        await until(
            () async =>
                row(0).evaluate().isNotEmpty && row(1).evaluate().isNotEmpty,
            'Both conversations should be visible');
      }

      Future<void> action(int index, String label) async {
        await tester.longPress(row(index));
        final item = find.text(label);
        await until(() async => item.hitTestable().evaluate().isNotEmpty,
            'Context menu action did not open: $label');
        await tester.pump(const Duration(milliseconds: 230));
        await tester.tap(item);
        await tester.pump(const Duration(milliseconds: 260));
        await until(() async => row(index).hitTestable().evaluate().isNotEmpty,
            'Chat row is still covered by the context menu');
      }

      const first = 'Практикум по оптике';
      const second = 'Перенос лабораторной';
      final firstId = await send(0, first);
      final secondId = await send(1, second);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await list();
      final search = find.byType(TextField);
      await tester.enterText(search, '  ОПТИКЕ  ');
      await until(
          () async =>
              row(0).evaluate().length == 1 && row(1).evaluate().isEmpty,
          'Searching the last message selected the wrong conversation');
      expect(inRow(0, find.text(first)), findsOneWidget);
      await tester.enterText(search, 'несуществующийфрагмент');
      await until(
          () async => row(0).evaluate().isEmpty && row(1).evaluate().isEmpty,
          'A no-match query kept a stale result');
      await tester.enterText(search, '');
      await until(
          () async =>
              row(0).evaluate().length == 1 && row(1).evaluate().length == 1,
          'Clearing search did not restore both conversations');
      debugPrint('PASS CHAT-01 search by last message, no-match and clear');

      bool firstAboveSecond() =>
          tester.getTopLeft(row(0)).dy < tester.getTopLeft(row(1)).dy;
      expect(firstAboveSecond(), isFalse);
      await action(0, 'Закрепить');
      await until(
          () async =>
              (await summary(0))['is_pinned'] == true && firstAboveSecond(),
          'Pin did not persist or reorder the list');
      await list();
      await until(
          () async => firstAboveSecond(), 'Reopening lost pinned order');
      await action(0, 'Открепить');
      await until(
          () async =>
              (await summary(0))['is_pinned'] == false && !firstAboveSecond(),
          'Removing pin did not restore chronological order');
      debugPrint('PASS CHAT-02 pin and unpin with server state and list order');

      final initialNotices = await notices();
      expect(initialNotices.where((n) => forMessage(n, firstId)), hasLength(1));
      expect(
          initialNotices.where((n) => forMessage(n, secondId)), hasLength(1));
      await action(0, 'Без звука');
      await until(
          () async =>
              (await summary(0))['is_muted'] == true &&
              inRow(0, find.byIcon(Icons.volume_off_rounded))
                  .evaluate()
                  .isNotEmpty,
          'Mute did not persist');
      final silentId = await send(0, 'Тихое продолжение');
      expect((await summary(0))['last_message_id'], silentId);
      expect((await notices()).where((n) => forMessage(n, silentId)), isEmpty);
      await list();
      await action(0, 'Со звуком');
      await until(() async => (await summary(0))['is_muted'] == false,
          'Unmute did not persist');
      const audible = 'Снова со звуком';
      final audibleId = await send(0, audible);
      await until(
          () async =>
              (await notices()).where((n) => forMessage(n, audibleId)).length ==
              1,
          'New notification missing after unmute');
      debugPrint(
          'PASS CHAT-03 mute suppresses new notification, unmute restores it');

      await list();
      expect(tester.getSize(find.byType(MyChatsScreen)), const Size(390, 844));
      await until(
          () async =>
              inRow(0, find.text(audible)).evaluate().length == 1 &&
              inRow(0, find.text('3')).evaluate().length == 1,
          'Fresh unread messages are missing');
      await action(0, 'Прочитано');
      await until(() async {
        final a = await summary(0);
        final b = await summary(1);
        final rows = await notices();
        final cursor = await owner
            .from('chat_reads')
            .select('last_read_message_id')
            .eq('user_id', accounts.first['recipientId'])
            .eq('chat_id', chat(0))
            .maybeSingle();
        return a['unread_count'] == 0 &&
            b['unread_count'] == 1 &&
            cursor?['last_read_message_id'] == audibleId &&
            rows.singleWhere((n) => forMessage(n, audibleId))['read_at'] !=
                null &&
            rows.singleWhere((n) => forMessage(n, secondId))['read_at'] ==
                null &&
            inRow(1, find.text('1')).evaluate().length == 1 &&
            inRow(0, find.text('3')).evaluate().isEmpty;
      }, 'Quick read failed to advance the cursor or changed another chat');
      expect(find.byType(MyChatsScreen), findsOneWidget);
      expect(find.byType(TeamDetailsScreen), findsNothing);
      debugPrint('PASS CHAT-04 quick read in portrait preserves neighboring unread');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      for (final peer in peers) {
        await peer.dispose();
      }
      await Supabase.instance.dispose();
      transport.close();
    }
  }, skip: !enabled);
}
