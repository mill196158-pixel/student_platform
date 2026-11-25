import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:flutter/services.dart';
import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_payload.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:student_platform/src/ui/learning/tabs/files_tab.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _LocalTransport extends http.BaseClient {
  final inner = IOClient(
      _RealSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final paths = <String>{};
  String? heldChat;
  final received = Completer<void>(), release = Completer<void>();
  bool failOlder = false;
  bool failSource = false;
  int sourceRequests = 0;
  int olderFailures = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != 'http://127.0.0.1:55321') {
      throw StateError('Local Supabase is required');
    }
    paths.add(request.url.path);
    if (request.url.path.endsWith('/messages') &&
        request.url.queryParameters['select'] == 'created_at') {
      sourceRequests++;
      if (failSource)
        throw const SocketException('Offline reading attachment source');
    }
    if (request is http.Request &&
        request.url.path.endsWith('/get_chat_messages_page')) {
      final body = jsonDecode(request.body) as Map;
      if (failOlder && body['p_before_at'] != null) {
        olderFailures++;
        throw const SocketException('Interrupted older page');
      }
      if (heldChat != null &&
          body['p_chat_id'] == heldChat &&
          !received.isCompleted) {
        final response = await inner.send(request);
        final data = await response.stream.toBytes();
        received.complete();
        await release.future;
        return http.StreamedResponse(Stream.value(data), response.statusCode,
            headers: response.headers, request: request);
      }
    }
    final response = await inner.send(request);
    if (response.statusCode >= 400 &&
        request.url.path.endsWith('/get_chat_messages_page')) {
      final bytes = await response.stream.toBytes();
      final data = jsonDecode(utf8.decode(bytes)) as Map;
      print(
          'History RPC returned HTTP ${response.statusCode} ${data["code"]} ${data["message"]}');
      return http.StreamedResponse(Stream.value(bytes), response.statusCode,
          headers: response.headers, request: request);
    }
    return response;
  }

  @override
  void close() => inner.close();
}

class _RealSockets extends HttpOverrides {}

void main() {
  final configFile = Platform.environment['STUDENT_MATERIALS_LOCAL_CONFIG'];
  final manifestFile = Platform.environment['STUDENT_MATERIALS_LOCAL_MANIFEST'];
  if (configFile != null && manifestFile != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets('online subject opens its real team chat and returns from Files',
      (tester) async {
    final config = jsonDecode(File(configFile!).readAsStringSync()) as Map;
    final ids = jsonDecode(File(manifestFile!).readAsStringSync()) as Map;
    final title = 'QA subject ${(ids['offering'] as String).substring(0, 8)}';
    final body =
        'QA subject discussion ${(ids['message'] as String).substring(0, 8)}';
    final transport = _LocalTransport();
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.app_links/events'),
        (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('keyboard_image_channel'), (_) async => null);
    await initializeDateFormatting('ru');
    await tester.runAsync(() => Supabase.initialize(
        url: 'http://127.0.0.1:55321',
        publishableKey: config['anonKey'] as String,
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false)));
    final client = Supabase.instance.client;
    addTearDown(transport.close);
    await tester.runAsync(() => client.auth.signInWithPassword(
        email: config['email'] as String,
        password: config['password'] as String));
    expect(client.auth.currentUser?.id == config['recipientId'], isTrue);
    await tester.pumpWidget(AuthSessionScopeHost(
        child: MaterialApp(
            theme: AppTheme.light().data, home: const InfoScreen())));
    Future<void> waitFor(Finder finder) async {
      for (var frame = 0; frame < 140 && finder.evaluate().isEmpty; frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      if (finder.evaluate().isEmpty && ids.containsKey('older')) {
        final panel = find.byType(FilesTab, skipOffstage: false);
        if (panel.evaluate().isNotEmpty) {
          final rows = panel.evaluate().first.read<TeamCubit>().state.chat;
          print(
              'UI missing $finder, requests=${transport.paths}, rows=${rows.length}, targetLoaded=${rows.any((r) => r.id == ids['older'])}, labels=${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().where((s) => s.contains('source') || s.contains('недоступно')).take(6).toList()}');
        }
      }
      expect(finder, findsWidgets);
      await tester.pump(const Duration(milliseconds: 300));
    }

    if (ids['switch'] == true) {
      transport.heldChat = ids['chat'] as String;
      await tester.pumpWidget(AuthSessionScopeHost(
          child: MaterialApp(
              theme: AppTheme.light().data, home: const MyChatsScreen())));
      final first = find.byKey(ValueKey<String>(ids['chat'] as String));
      final second = find.byKey(ValueKey<String>(ids['otherChat'] as String));
      await waitFor(first);
      await tester.ensureVisible(first);
      await waitFor(first.hitTestable());
      await tester.tap(first.hitTestable().first);
      for (var n = 0; n < 140 && !transport.received.isCompleted; n++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(transport.received.isCompleted, isTrue);
      await tester.binding.handlePopRoute();
      await waitFor(second);
      await tester.ensureVisible(second);
      await waitFor(second.hitTestable());
      await tester.tap(second.hitTestable().first);
      final sibling = find.text('Sibling source ${ids['chat']}');
      await waitFor(sibling);
      transport.release.complete();
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(sibling.hitTestable(), findsOneWidget);
      expect(find.text(body), findsNothing);
      final state = tester.element(sibling.first).read<TeamCubit>().state;
      expect(state.team.id, ids['otherTeam']);
      expect(state.chat.map((m) => m.chatId).toSet(), {ids['otherChat']});
      print('PASS 034 late response from first team left second chat intact');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await Supabase.instance.dispose();
      return;
    }
    await waitFor(find.text(title));
    await tester.ensureVisible(find.text(title).first);
    await tester.tap(find.text(title).first);
    await waitFor(find.text('Информация о предмете'));
    final action = find.text('Чат');
    await waitFor(action);
    await tester.ensureVisible(action.first);
    await tester.tap(action.first);
    await waitFor(find.byType(TeamDetailsScreen));
    await waitFor(find.text(body));
    if (ids['pushSame'] == true) {
      PushNavigation.markReady();
      final current = tester.element(find.text(body).first);
      unawaited(PushNavigation.handle(
          current,
          PushPayload(
            type: 'team_message',
            version: 1,
            chatId: ids['chat'],
            teamId: ids['team'],
            messageId: ids['message'],
          ),
          force: true));
      for (var i = 0; i < 28; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(
          find.byType(TeamDetailsScreen, skipOffstage: false), findsOneWidget);
      expect(find.text(body).hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await waitFor(find.text('Информация о предмете'));
      final outgoing = find.byType(TeamDetailsScreen, skipOffstage: false);
      for (var frame = 0;
          frame < 80 && outgoing.evaluate().isNotEmpty;
          frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(outgoing, findsNothing);
      PushNavigation.markNotReady();
      await tester.pumpWidget(const SizedBox.shrink());
      await Supabase.instance.dispose();
      print(
          'PASS 037 PushNavigation delivered an actual data payload to the open subject route; one Back returned to materials. Transport delivery independent.');
      return;
    }
    if (ids['uiPaging'] == true) {
      final list = find.descendant(
          of: find.byType(TeamDetailsScreen), matching: find.byType(ListView));
      await waitFor(list);
      final scrollable = find
          .descendant(of: list.last, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final cubit = tester.element(scrollable).read<TeamCubit>();
      final initial = cubit.state.chat.map((m) => m.id).toSet();
      expect(initial, hasLength(100));
      transport.failOlder = true;
      position.jumpTo(position.maxScrollExtent);
      for (var i = 0; i < 100 && transport.olderFailures == 0; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(transport.olderFailures, greaterThan(0));
      expect(cubit.state.chat.map((m) => m.id).toSet(), initial);
      transport.failOlder = false;
      position.jumpTo(position.maxScrollExtent - 450);
      await tester.pump();
      position.jumpTo(position.maxScrollExtent);
      for (var i = 0; i < 150 && cubit.state.chat.length < 123; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 30));
      }
      final all = cubit.state.chat;
      expect(all, hasLength(123));
      expect(all.map((m) => m.id).toSet(), hasLength(123));
      expect(all.map((m) => m.id).toSet(), containsAll(initial));
      expect(
          [for (final m in all) m.text].where((s) => s.startsWith('Sequence ')),
          [for (var n = 1; n <= 120; n++) 'Sequence $n']);
      print(
          'PASS 028 ordinary scroll retained 100 entries on network failure, retried to all 123 rows, ordered, no duplicates');
      final sent = await tester.runAsync(
          () => cubit.sendMessage('CAD student', 'After older pages'));
      expect(sent, isNotNull);
      final confirmed = await tester.runAsync(() => client
          .from('messages')
          .select('id')
          .eq('id', sent!)
          .eq('chat_id', ids['chat'])
          .single());
      expect(confirmed?['id'], sent);
      expect(cubit.state.chat.map((m) => m.id).toSet(),
          {...all.map((m) => m.id), sent});
      print(
          'PASS 028 all previously loaded older rows survived a confirmed ordinary send');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await Supabase.instance.dispose();
      return;
    }
    await tester.tap(find.text('Файлы').first);
    await tester.pump(const Duration(milliseconds: 350));
    if (ids.containsKey('older')) {
      final panel = find.byType(FilesTab);
      final documents =
          find.descendant(of: panel, matching: find.text('Файлы'));
      await waitFor(documents);
      await tester.tap(documents.first);
      await waitFor(find.text('Plan.dwg'));
      final sibling = await tester.runAsync(() => client
          .from('chat_files')
          .select('id')
          .eq('file_name', 'Plan.dwg')
          .inFilter('chat_id', [ids['chat'], ids['otherChat']]));
      expect(sibling, hasLength(2));
      await tester.tap(find.text('Plan.dwg').first);
      await waitFor(find.byType(FullscreenFileViewer));
      await tester.binding.handlePopRoute();
      await waitFor(find.text('Plan.dwg').hitTestable());
      expect(find.byType(TeamDetailsScreen), findsOneWidget);
      print('PASS 036 preview returned to the same Files tab');

      Finder source(String name) => find.byTooltip('К сообщению: $name');
      expect(source('Unattached.dwg'), findsNothing);
      await waitFor(source('Plan.dwg'));
      transport.failSource = true;
      await tester.tap(source('Plan.dwg'));
      await waitFor(
          find.text('Не удалось загрузить сообщение. Попробуйте ещё раз.'));
      expect(find.text('Сообщение не найдено или недоступно.'), findsNothing);
      transport.failSource = false;
      await tester.tap(find.text('Файлы').first);
      await waitFor(source('Plan.dwg'));
      print(
          'PASS 039 connection failure was distinguished from a removed attachment source');
      final clock = Stopwatch()..start();
      await tester.tap(source('Plan.dwg'));
      final target = find.byKey(ValueKey('message-${ids['older']}'));
      await waitFor(target);
      await waitFor(find
          .descendant(of: target, matching: find.textContaining('Plan.dwg'))
          .hitTestable());
      final active = tester
          .element(find.byType(FilesTab, skipOffstage: false).first)
          .read<TeamCubit>();
      final sourceRow =
          active.state.chat.singleWhere((m) => m.id == ids['older']);
      expect(sourceRow.chatId, ids['chat']);
      expect(sourceRow.authorId, config['peerId'] ?? config['recipientId']);
      expect(
          active.state.chat.any((m) => m.id == ids['otherMessage']), isFalse);
      print(
          'PASS 033 duplicate file name isolated to selected material, original author verified');
      print(
          'PASS 032 selected visible original outside first 100, ${clock.elapsedMilliseconds} ms');
      await tester.tap(find.text('Файлы').first);
      await waitFor(source('Removed.dwg'));
      await tester.runAsync(() => client
          .from('messages')
          .delete()
          .eq('id', ids['unavailable'] as String)
          .eq('chat_id', ids['chat'] as String));
      final deleted = await tester.runAsync(() => client
          .from('messages')
          .select('id')
          .eq('id', ids['unavailable'] as String)
          .maybeSingle());
      expect(deleted, isNull);
      await tester.tap(source('Removed.dwg'));
      await waitFor(find.text('Сообщение не найдено или недоступно.'));
      expect(find.byType(TeamDetailsScreen), findsOneWidget);
      expect(find.text('Removed source ${ids['chat']}').hitTestable(),
          findsNothing);
      print('PASS 039 deleted target unavailable in the original chat');
      await tester.tap(find.text('Файлы').first);
      await waitFor(source('Plan.dwg'));
      final ack =
          File(manifestFile.replaceFirst(RegExp(r'\.json$'), '.revoked'));
      await tester.runAsync(() async {
        await File(manifestFile.replaceFirst(RegExp(r'\.json$'), '.revoke'))
            .create();
        for (var i = 0; i < 180 && !await ack.exists(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
      });
      expect(ack.existsSync(), isTrue);
      final previousRequests = transport.sourceRequests;
      ScaffoldMessenger.of(tester.element(source('Plan.dwg')))
          .removeCurrentSnackBar();
      await tester.pump();
      await tester.tap(source('Plan.dwg'));
      for (var n = 0;
          n < 120 && transport.sourceRequests == previousRequests;
          n++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(transport.sourceRequests, greaterThan(previousRequests));
      await waitFor(find.text('Сообщение не найдено или недоступно.'));
      expect(find.byType(TeamDetailsScreen), findsOneWidget);
      final denial = await tester.runAsync(() async {
        try {
          await client.rpc('get_chat_messages_page',
              params: {'p_chat_id': ids['chat'], 'p_limit': 1});
          return null;
        } on PostgrestException catch (error) {
          return (error.code, error.message);
        }
      });
      expect(denial, ('P0001', 'forbidden'));
      print(
          'PASS 032/039 stale file click after membership removal received denial from current-user history RPC');

      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      await waitFor(find.text('Информация о предмете'));
      for (var frame = 0;
          frame < 40 && find.byType(TeamDetailsScreen).evaluate().isNotEmpty;
          frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.byType(TeamDetailsScreen), findsNothing);
    } else {
      await tester.tap(find.text('Чат').first);

      await waitFor(find.text(body));
    }
    expect(
        transport.paths,
        containsAll([
          '/auth/v1/token',
          '/rest/v1/teams',
          '/rest/v1/chats',
          '/rest/v1/rpc/get_chat_messages_page'
        ]));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await Supabase.instance.dispose().timeout(const Duration(seconds: 12));
  }, skip: configFile == null || manifestFile == null);
}
