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
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/data/chat_summaries_cache.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _LocalSockets extends HttpOverrides {}

class _SettingsOutage extends http.BaseClient {
  final _transport = IOClient(
      _LocalSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  var settingsUnavailable = true;
  int rejected = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (settingsUnavailable &&
        request.method == 'POST' &&
        request.url.path == '/rest/v1/chat_user_settings') {
      rejected++;
      return Future.value(http.StreamedResponse(
          Stream.value(utf8
              .encode('{"code":"503","message":"temporarily unavailable"}')),
          503,
          request: request,
          reasonPhrase: 'Service unavailable',
          headers: {'content-type': 'application/json'}));
    }
    return _transport.send(request);
  }

  @override
  void close() => _transport.close();
}

void main() {
  final configPaths = Platform.environment['STUDENT_CHAT_SWITCH_CONFIGS'];
  final manifest = Platform.environment['STUDENT_CHAT_SWITCH_MANIFEST'];
  if (configPaths != null && manifest != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets(
      'opening one chat reads its messages and preserves the neighboring discussion',
      (tester) async {
    const url = 'http://127.0.0.1:55321';
    final configs = [
      for (final p in jsonDecode(configPaths!) as List)
        jsonDecode(File(p).readAsStringSync())
    ];
    final teams = jsonDecode(File(manifest!).readAsStringSync()) as List;
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.app_links/events'),
        (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('keyboard_image_channel'), (_) async => null);
    final http = _SettingsOutage();
    await initializeDateFormatting('ru');
    await Supabase.initialize(
        url: url,
        publishableKey: configs[0]['anonKey'],
        httpClient: http,
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false));
    final recipient = Supabase.instance.client;
    final clients = [
      recipient,
      for (final c in configs.skip(1))
        SupabaseClient(url, c['anonKey'],
            httpClient: http,
            authOptions: const AuthClientOptions(autoRefreshToken: false))
    ];
    try {
      for (var i = 0; i < clients.length; ++i) {
        final auth = await clients[i].auth.signInWithPassword(
            email: configs[i]['email'], password: configs[i]['password']);
        expect(auth.user?.id == configs[i]['recipientId'], isTrue);
      }
      Future<void> send(int index, String body) async {
        await clients[index + 1].rpc('send_chat_message',
            params: {'p_team_id': teams[index]['team'], 'p_text': body});
      }

      Future<List<int>> receipts() async {
        final rows = await recipient
            .rpc('get_my_app_notifications', params: {'p_limit': 50}) as List;
        return [
          for (final t in teams)
            rows
                .where((r) =>
                    r['data']['chat_id'] == t['chat'] && r['read_at'] == null)
                .length
        ];
      }

      Future<List<int>> unread() async {
        final rows = await recipient.rpc('get_my_chat_summaries') as List;
        return [
          for (final t in teams)
            rows.singleWhere((r) => r['chat_id'] == t['chat'])['unread_count']
                as int
        ];
      }

      Future<void> until(Future<bool> Function() check, String reason) async {
        for (int i = 0; i < 100; i++) {
          if (await check()) return;
          await tester.pump(const Duration(milliseconds: 70));
        }
        fail(reason);
      }

      final first = 'First initial ${teams[0]['team']}';
      final second = 'Second initial ${teams[1]['team']}';
      final late = 'First late ${teams[0]['team']}';
      await send(0, first);
      await send(1, second);
      expect(await unread(), [1, 1]);
      expect(await receipts(), [1, 1]);
      await ChatSummariesCache.write(
          configs[0]['recipientId'],
          jsonEncode([
            for (int index = 0; index < teams.length; index++)
              {
                'chatId': teams[index]['chat'],
                'team': {
                  'id': teams[index]['team'],
                  'name': 'Old title',
                  'kind': 'subject'
                },
                'title': 'Old title',
                'unread': 0,
                'pinned': index == 0,
                'muted': index == 1,
              },
          ]));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
          const AuthSessionScopeHost(child: SizedBox(key: Key('signed in'))));
      await AuthSessionScopeHost.maybeRead(
              tester.element(find.byKey(const Key('signed in'))))!
          .ready;
      await tester.pumpWidget(AuthSessionScopeHost(
          child: MaterialApp(
              theme: AppTheme.light().data, home: const MyChatsScreen())));
      Finder row(int index) =>
          find.byKey(ValueKey<String>(teams[index]['chat'] as String));
      Future<void> open(int index, String body) async {
        await until(() async => row(index).evaluate().isNotEmpty,
            'Chat row did not appear');
        await tester.ensureVisible(row(index));
        await tester.tap(row(index));
        await until(
            () async =>
                find.byType(TeamDetailsScreen).evaluate().isNotEmpty &&
                find.text(body).evaluate().isNotEmpty,
            'Selected message did not open');
      }

      Future<void> back() async {
        await tester.tap(find.byTooltip('Назад'));
        await tester.pump(const Duration(milliseconds: 400));
      }

      Future<void> counts(int a, int b) async {
        bool matches(List<int> actual) => actual[0] == a && actual[1] == b;
        await until(
            () async => matches(await unread()) && matches(await receipts()),
            'Chat cursor and notifications did not converge to [$a,$b]');
      }

      Finder badge(int group) =>
          find.descendant(of: row(group), matching: find.text('1'));
      await until(
          () async => http.rejected > 0, 'Settings outage was not exercised');
      await until(
          () async =>
              badge(0).evaluate().length == 1 &&
              badge(1).evaluate().length == 1,
          'Both chats were received but failed to appear during settings outage');
      Finder muteIcon(int group) => find.descendant(
          of: row(group), matching: find.byIcon(Icons.volume_off_rounded));
      expect(muteIcon(1), findsOneWidget);
      http.settingsUnavailable = false;
      // Another session has already changed the second chat's preferences.
      await recipient.from('chat_user_settings').insert({
        'user_id': configs[0]['recipientId'],
        'chat_id': teams[1]['chat'],
        'is_muted': false,
      });
      await open(0, first);
      await counts(0, 1);
      await back();
      await until(
          () async =>
              badge(0).evaluate().isEmpty && badge(1).evaluate().length == 1,
          'Reading the first chat did not update its list badge');
      await until(() async {
        final rows = await recipient.rpc('get_my_chat_summaries') as List;
        final a = rows.singleWhere((r) => r['chat_id'] == teams[0]['chat']);
        final b = rows.singleWhere((r) => r['chat_id'] == teams[1]['chat']);
        return a['settings_exists'] == true &&
            a['is_pinned'] == true &&
            b['is_muted'] == false &&
            muteIcon(1).evaluate().isEmpty;
      }, 'Recovery failed to migrate the local pin or overwrote the newer mute setting');
      await open(1, second);
      await counts(0, 0);
      await send(0, late);
      await counts(1, 0);
      expect(find.text(late), findsNothing);
      await back();
      await until(
          () async =>
              badge(0).evaluate().length == 1 && badge(1).evaluate().isEmpty,
          'New message in the other discussion did not update its badge');
      await open(0, late);
      await counts(0, 0);
      await back();
      await until(
          () async =>
              badge(0).evaluate().isEmpty && badge(1).evaluate().isEmpty,
          'Final badge did not clear');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      for (final client in clients.skip(1)) {
        await client.dispose();
      }
      await Supabase.instance.dispose().timeout(const Duration(seconds: 12));
      http.close();
    }
  }, skip: configPaths == null || manifest == null);
}
