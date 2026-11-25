import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _local = 'http://127.0.0.1:55321';

class _LocalSockets extends HttpOverrides {}

// Flutter uses its real HTTP client; only the REST origin changes to select the
// per-run PostgREST container. Sign-in still goes to the local GoTrue instance.
class _ArchiveClient extends http.BaseClient {
  _ArchiveClient(this.port);
  final int port;
  final transport = IOClient(
      _LocalSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _local) throw StateError('Non-local host');
    const prefix = '/rest/v1';
    if (!request.url.path.startsWith('$prefix/'))
      return transport.send(request);
    final uri = request.url
        .replace(port: port, path: request.url.path.substring(prefix.length));
    return transport.send(http.Request(request.method, uri)
      ..followRedirects = false
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes());
  }

  @override
  void close() => transport.close();
}

void main() {
  final config = Platform.environment['STUDENT_ARCHIVE_LOCAL'];
  if (config != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets(
      'archive, inspect, restore, hide and receive a new direct message',
      (tester) async {
    final data = jsonDecode(config!) as Map<String, dynamic>;
    final schema = data['schema'] as String;
    expect(schema, matches(RegExp(r'^e2e_archive_[0-9a-f]{12}$')));
    final accounts = data['accounts'] as List;
    final chat = data['chat'] as String;
    final transport = _ArchiveClient(data['restPort'] as int);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/events'),
            (_) async => null);
    await initializeDateFormatting('ru');
    final rest = PostgrestClientOptions(schema: schema);
    await Supabase.initialize(
        url: _local,
        publishableKey: data['anon'],
        authOptions: const FlutterAuthClientOptions(
            detectSessionInUri: false, autoRefreshToken: false),
        httpClient: transport,
        postgrestOptions: rest);
    final owner = Supabase.instance.client;
    final peer = SupabaseClient(_local, data['anon'],
        httpClient: transport,
        postgrestOptions: rest,
        authOptions: const AuthClientOptions(autoRefreshToken: false));
    final clients = [owner, peer];
    try {
      for (var i = 0; i < clients.length; i++) {
        final result = await clients[i].auth.signInWithPassword(
            email: accounts[i]['email'], password: accounts[i]['password']);
        expect(result.user?.id, accounts[i]['id']);
      }
      Future<List> rows(SupabaseClient client, {bool archived = false}) async =>
          (await client.rpc(archived
                  ? 'get_my_archived_chat_summaries'
                  : 'get_my_chat_summaries') as List)
              .where((r) => r['chat_id'] == chat)
              .toList();
      Future<String> send(String message) async =>
          await peer.rpc('send_message_in_chat_with_files',
              params: {'p_chat_id': chat, 'p_text': message}) as String;
      Future<List> history(SupabaseClient client) async => (await client
                  .rpc('get_chat_messages_page', params: {'p_chat_id': chat})
              as List)
          .map((row) => row['id'])
          .toList();
      Future<void> until(bool Function() predicate, String message) async {
        final end = DateTime.now().add(const Duration(seconds: 7));
        while (!predicate() && DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        expect(predicate(), isTrue, reason: message);
      }

      Future<void> wait(Finder finder) =>
          until(() => finder.evaluate().isNotEmpty, 'Missing $finder');
      Future<void> tap(Finder finder) async {
        await until(() => finder.hitTestable().evaluate().isNotEmpty,
            'Cannot tap $finder');
        await tester.tap(finder.hitTestable().first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 360));
      }

      Future<void> menu(Finder row, String action) async {
        await until(() => row.hitTestable().evaluate().isNotEmpty,
            'Cannot open menu for covered row $row');
        await tester.longPress(row.hitTestable().first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tap(find.text(action));
      }

      const before = 'Как прошёл зачёт?';
      Future<void> archivedMenu(String action) async {
        final item = find.text(before);
        await until(() => item.hitTestable().evaluate().isNotEmpty,
            'Archived conversation is covered');
        final gesture = await tester.startGesture(tester.getCenter(item));
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('Вернуть из архива'), findsNothing);
        await gesture.moveBy(const Offset(0, 8));
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await wait(find.text('Вернуть из архива'));
        await wait(find.text('Удалить у себя'));
        expect(find.byType(AlertDialog), findsNothing);
        expect(await rows(owner, archived: true), hasLength(1),
            reason: 'Lifting a finger should only open the menu');
        await tap(find.text(action));
      }

      Future<void> pull() async {
        await tester.drag(find.byKey(const PageStorageKey('chats_list')),
            const Offset(0, 380));
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 110));
        }
      }

      Future<void> openArchive() async {
        await tap(find.byTooltip('Ещё'));
        await tap(find.text('Архив'));
        await wait(find.text('Учебные'));
      }

      const after = 'Увидимся на новой паре';
      const peerName = 'Boris Archive';
      final dm = find.byKey(ValueKey(chat));
      final firstId = await send(before);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
          const AuthSessionScopeHost(child: SizedBox(key: Key('ready'))));
      await AuthSessionScopeHost.maybeRead(
              tester.element(find.byKey(const Key('ready'))))!
          .ready;
      const team = Team(
          id: 'archive-host', name: '', teacher: '', groupCode: '', icon: '');
      await tester.pumpWidget(AuthSessionScopeHost(
          child: BlocProvider(
              create: (_) => TeamCubit(team),
              child: MaterialApp(
                  theme: AppTheme.light().data,
                  home: const MyChatsScreen(enableRealtime: false)))));
      await wait(dm);
      await wait(find.descendant(of: dm, matching: find.text(before)));
      await menu(dm, 'В архив');
      await until(() => dm.evaluate().isEmpty,
          'Archiving should remove the active row');
      await pull();
      expect(await rows(owner), isEmpty,
          reason: 'Archived DM returned in active summaries after refreshing');
      expect(dm, findsNothing);
      expect((await rows(owner, archived: true)).single['last_message_id'],
          firstId);
      expect((await rows(peer)).single['last_message_id'], firstId);
      expect(await rows(peer, archived: true), isEmpty);
      debugPrint(
          'PASS ARCH-01 archive persists on refresh for owner, peer still has an active conversation');

      await openArchive();
      await wait(find.text('Archive Mechanics'));
      expect(find.text('Осенний семестр'), findsOneWidget);
      final available = DateFormat('d MMMM yyyy', 'ru')
          .format(DateTime.parse(data['available']));
      expect(find.text('Доступен до $available'), findsOneWidget);
      expect(find.text(peerName), findsNothing);
      await tap(find.text('Личные'));
      await wait(find.text(peerName));
      expect(find.text(before), findsOneWidget);
      expect(find.text('Archive Mechanics'), findsNothing);
      debugPrint(
          'PASS ARCH-02 distinguish academic semester/expiry from archived personal conversations');

      await archivedMenu('Вернуть из архива');
      await wait(find.textContaining('Здесь появятся личные диалоги'));
      expect((await rows(owner)).single['last_message_id'], firstId);
      expect((await rows(peer)).single['last_message_id'], firstId);
      await tap(find.byType(BackButton));
      await wait(find.text('Сообщения'));
      await until(() => dm.evaluate().isNotEmpty,
          'Restored DM missing on return from Archive without a manual refresh');
      expect(find.text(before), findsOneWidget);
      debugPrint(
          'PASS ARCH-03 restore archived DM and see it immediately after the normal Back action');

      await menu(dm, 'В архив');
      await until(
          () => dm.evaluate().isEmpty, 'DM should disappear on repeat archive');
      await openArchive();
      await tap(find.text('Личные'));
      await wait(find.text(peerName));
      await archivedMenu('Удалить у себя');
      await tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(before), findsOneWidget);
      expect((await rows(owner, archived: true)).single['last_message_id'],
          firstId);
      await archivedMenu('Удалить у себя');
      await tap(find.text('Удалить'));
      await wait(find.textContaining('Здесь появятся личные диалоги'));
      expect(await rows(owner, archived: true), isEmpty);
      expect(await rows(owner), isEmpty);
      expect((await rows(peer)).single['last_message_id'], firstId);
      expect(await history(owner), isEmpty);
      expect(await history(peer), [firstId]);
      await tap(find.byType(BackButton));
      await wait(find.text('Сообщения'));
      await pull();
      expect(dm, findsNothing);
      debugPrint(
          'PASS ARCH-04 cancel then confirm hide for me; previous message survives for peer');

      final latest = await send(after);
      await pull();
      await wait(find.descendant(of: dm, matching: find.text(after)));
      expect(find.text(before), findsNothing);
      final own = (await rows(owner)).single;
      final other = (await rows(peer)).single;
      expect(own['last_message_id'], latest);
      expect(own['unread_count'], 1,
          reason: 'Earlier cleared messages must not count as unread');
      expect(other['last_message_id'], latest);
      expect(other['unread_count'], 0);
      expect(await rows(owner, archived: true), isEmpty);
      expect(await history(owner), [latest]);
      expect(await history(peer), containsAll([firstId, latest]));
      debugPrint(
          'PASS ARCH-05 new peer message restores DM on pull-to-refresh with only one new unread');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
      await peer.auth.signOut();
      await owner.auth.signOut();
      await peer.dispose();
      await Supabase.instance.dispose();
      transport.close();
    }
  }, skip: config == null, timeout: const Timeout(Duration(minutes: 3)));
}
