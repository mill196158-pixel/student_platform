import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/notifications/notification_settings_screen.dart';
import 'package:student_platform/src/ui/profile/edit_profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _origin = 'http://127.0.0.1:55321';

class _LocalSockets extends HttpOverrides {}

class _LocalHttp extends http.BaseClient {
  final _inner = IOClient(
      _LocalSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  String? unavailable;
  int refused = 0;
  int preferenceWrites = 0;
  Future<void> Function()? afterStatusWrite;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _origin) throw StateError('Loopback only');
    final path = request.url.pathSegments.last;
    if (path == 'update_my_notification_preferences') preferenceWrites++;
    if (unavailable == path && (path != 'users' || request.method == 'PATCH')) {
      refused++;
      return http.StreamedResponse(
          Stream.value(utf8.encode('{"message":"Local QA offline"}')), 503,
          headers: {'content-type': 'application/json'}, request: request);
    }
    final response = await _inner.send(request);
    if (path == 'users' &&
        request.method == 'PATCH' &&
        response.statusCode == 200) {
      await afterStatusWrite?.call();
    }
    return response;
  }

  @override
  void close() => _inner.close();
}

void main() {
  final raw = Platform.environment['STUDENT_PROFILE_SCENARIOS'];
  if (raw != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets('profile and notification journeys with two local students',
      (tester) async {
    final config = jsonDecode(raw!) as Map;
    final students = (config['students'] as List).cast<Map>();
    if (config['api'] != _origin ||
        students.length != 2 ||
        students.first['id'] == students.last['id'] ||
        students.any((s) =>
            !RegExp(r'^e2e_social_[0-9a-f]{12}_(first|peer)@student\.local$')
                .hasMatch(s['email'] as String))) {
      throw StateError('Disposable local student identities required');
    }
    await HttpOverrides.runWithHttpOverrides(() async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('com.llfbandit.app_links/events'),
              (_) async => null);
      final transport = _LocalHttp();
      await Supabase.initialize(
          url: _origin,
          publishableKey: config['key'],
          httpClient: transport,
          authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false, detectSessionInUri: false));
      final me = Supabase.instance.client;
      final peer = SupabaseClient(_origin, config['key']);
      final fresh = SupabaseClient(_origin, config['key']);
      final router = GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
                body: Center(
                    child: TextButton(
                        onPressed: () => context.push('/profile/edit'),
                        child: const Text('Открыть профиль'))))),
        GoRoute(
            path: '/profile/edit',
            builder: (_, state) => const EditProfileScreen()),
        GoRoute(
            path: '/notification-settings',
            builder: (_, state) => const NotificationSettingsScreen()),
      ]);

      Future<void> until(
          FutureOr<bool> Function() predicate, String reason) async {
        final end = DateTime.now().add(const Duration(seconds: 12));
        while (DateTime.now().isBefore(end)) {
          if (await predicate()) return;
          await tester.pump(const Duration(milliseconds: 45));
        }
        fail(reason);
      }

      Future<void> visible(Finder target) =>
          until(() => target.evaluate().isNotEmpty, 'Missing $target');
      Future<void> tap(Finder target) async {
        await visible(target);
        await until(() async {
          await Scrollable.ensureVisible(tester.element(target.first),
              alignment: .5);
          return target.first.hitTestable().evaluate().isNotEmpty;
        }, 'Cannot tap $target');
        await tester.tap(target.first);
        await tester.pump(const Duration(milliseconds: 330));
      }

      Future<void> back() async {
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 380));
      }

      Finder toggle(String label) => find.descendant(
          of: find.ancestor(of: find.text(label), matching: find.byType(Row)),
          matching: find.byType(Switch));
      Future<void> revealSwitch(String label) async {
        final list = find.descendant(
            of: find.byType(NotificationSettingsScreen),
            matching: find.byType(ListView));
        await visible(list);
        await tester.scrollUntilVisible(find.text(label), 160,
            scrollable: find
                .descendant(of: list, matching: find.byType(Scrollable))
                .first);
        await tester.ensureVisible(toggle(label));
      }

      Future<void> setSwitch(
          String label, String preference, bool value) async {
        await revealSwitch(label);
        final item = toggle(label);
        await visible(item);
        if (tester.widget<Switch>(item).value != value) await tap(item);
        await until(
            () =>
                tester.widget<Switch>(item).value == value &&
                tester.widget<Switch>(item).onChanged != null,
            'Switch did not settle: $label');
        expect((await me.rpc('get_my_notification_preferences'))[preference],
            value);
      }

      Future<String> post(SupabaseClient sender, String body,
          {String? reply}) async {
        final row = await sender
            .from('messages')
            .insert({
              'chat_id': config['chat'],
              'author_id': sender.auth.currentUser!.id,
              'body': body,
              'content': body,
              'msg_type': 'text',
              'reply_to_id': reply,
            })
            .select('id')
            .single();
        return row['id'] as String;
      }

      Future<List<Map>> notices(String messageId) async =>
          (await me.rpc('get_my_app_notifications') as List)
              .cast<Map>()
              .where((n) => n['data']['message_id'] == messageId)
              .toList();
      try {
        for (final (client, student) in [
          (me, students.first),
          (peer, students.last)
        ]) {
          final signed = await client.auth.signInWithPassword(
              email: student['email'], password: student['password']);
          expect(signed.user?.id, student['id']);
        }
        final uid = me.auth.currentUser!.id;
        final cache = await SharedPreferences.getInstance();
        Future<Map> profile() => me
            .from('users')
            .select('id,name,surname,group_name,status')
            .eq('id', uid)
            .single();
        await cache.setString('user', jsonEncode(await profile()));
        await tester.pumpWidget(AuthSessionScopeHost(
            child: MaterialApp.router(
                theme: AppTheme.light().data, routerConfig: router)));
        await tap(find.text('Открыть профиль'));
        await visible(find.text(students.first['surname']));

        await tap(find.text('Уведомления'));
        await setSwitch('Все сообщения групп', 'group_all_messages', true);
        await setSwitch('Текст в уведомлении', 'show_message_preview', false);
        final sensitive = 'private-${config['chat']}';
        final hidden = (await notices(await post(peer, sensitive))).single;
        expect(hidden['data']['author_id'], peer.auth.currentUser!.id);
        expect(hidden['body'], contains('новое сообщение'));
        expect(hidden['body'], isNot(contains(sensitive)));
        await setSwitch('Текст в уведомлении', 'show_message_preview', true);
        final publicText = 'visible-${config['chat']}';
        expect((await notices(await post(peer, publicText))).single['body'],
            contains(publicText));
        debugPrint(
            'PASS PROFILE-1 hide and restore group notification previews');

        await setSwitch('Все сообщения групп', 'group_all_messages', false);
        await setSwitch('Ответы в группах', 'group_replies', true);
        final root = await post(me, 'Question for my group');
        final ordinary = await post(peer, 'A separate group message');
        final reply = await post(peer, 'An answer for the author', reply: root);
        expect(await notices(ordinary), isEmpty);
        expect(
            (await me
                .from('messages')
                .select('content')
                .eq('id', ordinary)
                .single())['content'],
            'A separate group message');
        final answer = (await notices(reply)).single;
        expect(answer['data']['type'], 'team_reply');
        expect(answer['data']['chat_id'], config['chat']);
        debugPrint(
            'PASS PROFILE-2 receive replies only while ordinary posts stay in the group');

        await setSwitch('Текст в уведомлении', 'show_message_preview', false);
        await back();
        final writes = transport.preferenceWrites;
        transport.unavailable = 'get_my_notification_preferences';
        await tap(find.text('Уведомления'));
        await until(() => transport.refused > 0,
            'Read outage did not reach real settings screen');
        await visible(find.text('Повторить'));
        expect(find.byType(Switch), findsNothing);
        expect(transport.preferenceWrites, writes);
        transport.unavailable = null;
        await tap(find.text('Повторить'));
        await revealSwitch('Текст в уведомлении');
        expect(
            tester.widget<Switch>(toggle('Текст в уведомлении')).value, false);
        expect(transport.preferenceWrites, writes);
        await back();
        debugPrint(
            'PASS PROFILE-3 reload previously saved privacy settings after a read outage');

        final failures = transport.refused;
        transport.unavailable = 'users';
        await tap(find.text('Онлайн'));
        await tap(find.text('В библиотеке'));
        await until(() => transport.refused > failures,
            'Status write outage did not reach the server boundary');
        await visible(find.text('Не удалось сохранить статус'));
        expect(find.text('Онлайн'), findsWidgets);
        expect((await profile())['status'], 'Онлайн');
        transport.unavailable = null;
        var refreshed = false;
        transport.afterStatusWrite = () async {
          final before = me.auth.currentSession!.accessToken;
          final next = await me.auth.refreshSession();
          refreshed =
              next.user?.id == uid && next.session?.accessToken != before;
        };
        await tap(find.text('Онлайн'));
        await tap(find.text('В библиотеке'));
        await until(
            () async =>
                (await profile())['status'] == 'В библиотеке' &&
                jsonDecode(cache.getString('user')!)['status'] ==
                    'В библиотеке',
            'Status not saved');
        await back();
        await tap(find.text('Открыть профиль'));
        await visible(find.text('В библиотеке'));
        expect(refreshed, isTrue,
            reason: 'The retry crossed a real token refresh');
        debugPrint(
            'PASS PROFILE-4 retry a failed status change and reopen the saved profile');

        final student = students.first;
        final exact = ' ${student['password']}next ';
        await tap(find.text('Сменить пароль'));
        final inputs = find.byType(TextFormField);
        await tester.enterText(inputs.at(0), exact);
        await tester.enterText(inputs.at(1), exact.trim());
        await tap(find.text('Сохранить пароль'));
        await visible(find.text('Пароли не совпадают'));
        await tester.enterText(inputs.at(1), exact);
        await tap(find.text('Сохранить пароль'));
        await visible(find.text('Пароль изменён'));
        await expectLater(
            fresh.auth.signInWithPassword(
                email: student['email'], password: student['password']),
            throwsA(isA<AuthException>()));
        final reopened = await fresh.auth
            .signInWithPassword(email: student['email'], password: exact);
        expect(reopened.user?.id, uid);
        debugPrint(
            'PASS PROFILE-5 correct a mismatched confirmation and sign in with the exact new password');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        router.dispose();
        await fresh.dispose();
        await peer.dispose();
        await Supabase.instance.dispose();
        transport.close();
      }
    }, _LocalSockets());
  }, skip: raw == null);
}
