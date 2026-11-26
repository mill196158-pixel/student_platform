import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:student_platform/src/ui/learning/account_draft_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat_tab.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'support/in_memory_realtime_socket.dart';

class _DraftDirectory extends PathProviderWindows {
  _DraftDirectory(this.folder);
  final String folder;
  @override
  Future<String?> getApplicationSupportPath() async => folder;
}

class _Sockets extends HttpOverrides {}

class _Loopback extends http.BaseClient {
  _Loopback(this.offline);
  bool offline;
  final http.Client inner =
      IOClient(_Sockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final requests = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != 'http://127.0.0.1:55321')
      throw StateError('Only local Supabase is allowed');
    requests.add(request.url.path);
    if (offline) throw const SocketException('Offline phase');
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  final storage = Platform.environment['STUDENT_RESTART_STORAGE'];
  final offline = Platform.environment['STUDENT_RESTART_PHASE'] == 'offline';
  final clean = Platform.environment['STUDENT_RESTART_PHASE'] == 'clean-device';
  if (storage != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets(
      'materials and chat on a new process using existing SQLite history',
      (tester) async {
    final cfg = jsonDecode(
        File(Platform.environment['STUDENT_MATERIALS_LOCAL_CONFIG']!)
            .readAsStringSync()) as Map;
    final ids = jsonDecode(
        File(Platform.environment['STUDENT_MATERIALS_LOCAL_MANIFEST']!)
            .readAsStringSync()) as Map;
    final sessionFile = File('$storage/session.json');
    if (clean) {
      expect(sessionFile.existsSync(), isFalse);
      expect(File('$storage/history.db').existsSync(), isFalse);
    }
    final transport = _Loopback(offline);
    if (ids['drafts'] == true) {
      SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
        ..pathProvider = _DraftDirectory(storage!);
    } else {
      SharedPreferences.setMockInitialValues({});
    }
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'com.llfbandit.app_links/events',
      'keyboard_image_channel'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(channel), (_) async => null);
    }
    await initializeDateFormatting('ru');
    if (Platform.isWindows)
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    await tester.runAsync(() => Supabase.initialize(
        url: 'http://127.0.0.1:55321',
        publishableKey: cfg['anonKey'] as String,
        httpClient: transport,
        realtimeClientOptions: ids['events'] == true && !offline
            ? const RealtimeClientOptions()
            : RealtimeClientOptions(
                transport: (_, __) => InMemoryRealtimeSocket()),
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false)));
    final auth = Supabase.instance.client.auth;
    if (offline) {
      await tester
          .runAsync(() => auth.recoverSession(sessionFile.readAsStringSync()));
    } else {
      await tester.runAsync(() => auth.signInWithPassword(
          email: cfg['email'] as String, password: cfg['password'] as String));
      sessionFile.writeAsStringSync(jsonEncode(auth.currentSession!.toJson()),
          flush: true);
    }
    expect(auth.currentUser!.id, cfg['recipientId']);
    final scope = AuthSessionScope(
        currentSession: () => auth.currentSession,
        authEvents: auth.onAuthStateChange);
    await tester
        .runAsync(() => scope.ready.timeout(const Duration(seconds: 6)));
    final jwt = auth.currentSession!.accessToken;
    final claims = jsonDecode(utf8.decode(
        base64Url.decode(base64Url.normalize(jwt.split('.')[1])))) as Map;
    final issuer = claims['iss'] as String;
    final binding =
        OfflineSessionBinding.fromSession(auth.currentSession!, issuer);
    expect(binding, isNotNull);
    final db = (await tester.runAsync(() => openProjectChatServerDatabase(
        '$storage/history.db',
        factory: databaseFactoryFfi)))!;
    final store = ProjectChatServerCache(
        db: db,
        scope: scope,
        currentBinding: () => binding,
        project: 'http://127.0.0.1:55321');
    ProjectChatServerCache.qaInstance = store;
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(
            offline
                ? SessionCapabilityMode.cacheOnly
                : SessionCapabilityMode.online,
            caps.beginAuthorization(scope.capture()!)!),
        isTrue);
    final start = Stopwatch()..start();
    await tester.pumpWidget(AuthSessionScopeHost(
        createScope: () => scope,
        child: MaterialApp(
            theme: AppTheme.light().data,
            home: clean
                ? const SizedBox()
                : offline
                    ? InfoScreen(cachedStore: store, cachedCapabilities: caps)
                    : const InfoScreen())));
    Future<void> wait(Finder finder) async {
      for (var t = 0; t < 180 && finder.evaluate().isEmpty; t++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 35)));
        await tester.pump(const Duration(milliseconds: 35));
      }
      expect(finder, findsWidgets);
    }

    Future<void> openDirect(String role, bool cached) async {
      final team = Team(
          id: ids[role.isEmpty ? 'team' : '${role}Team'] as String,
          name: 'QA $role',
          teacher: '',
          groupCode: '',
          icon: '');
      await tester.pumpWidget(AuthSessionScopeHost(
          createScope: () => scope,
          child: MaterialApp(
              key: ValueKey('$role-$cached'),
              theme: AppTheme.light().data,
              home: TeamDetailsScreen(
                  team: team,
                  cachedStore: cached ? store : null,
                  cachedCapabilities: cached ? caps : null,
                  cachedChatId:
                      cached ? ids[role.isEmpty ? 'chat' : '${role}Chat'] as String : null))));
    }

    if (clean) {
      transport.requests.clear();
      transport.offline = true;
      expect(
          caps.grant(SessionCapabilityMode.cacheOnly,
              caps.beginAuthorization(scope.capture()!)!),
          isTrue);
      await openDirect('cold', true);
      await wait(find.text('Сохранённые сообщения недоступны.'));
      expect(transport.requests, isEmpty);
      transport.offline = false;
      expect(
          caps.grant(SessionCapabilityMode.online,
              caps.beginAuthorization(scope.capture()!)!),
          isTrue);
      // Each online conversation is opened for the first time. SQLite rejects
      // either the cache ticket or the confirmed page, while PostgREST is live.
      for (final (table, role, chat, marker) in [
        ('chat_server_attempt', 'cold', ids['coldChat'], 'Cold history marker'),
        ('chat_server_snapshot', 'other', ids['otherChat'], 'Sibling source ${ids['chat']}'),
      ]) {
        await tester.runAsync(() => db.execute('''
          CREATE TRIGGER qa_refuse_history BEFORE INSERT ON $table
          BEGIN SELECT RAISE(ABORT, 'history write unavailable'); END
        '''));
        try {
          transport.requests.clear();
          await openDirect(role, false);
          await wait(find.text(marker));
          expect(transport.requests, contains('/rest/v1/rpc/get_chat_messages_page'));
          final snapshots = await tester.runAsync(() => db.query(
              'chat_server_snapshot', where: 'chat = ?', whereArgs: [chat]));
          expect(snapshots, isEmpty);
        } finally {
          await tester.runAsync(() => db.execute('DROP TRIGGER qa_refuse_history'));
        }
      }
      print(
          'PASS 026 new independent Windows process, absent database and preferences, original student signed in online before first chat, no history offline, same real server marker after reconnect');
      print('PASS online rows remain visible after real SQLite ticket and snapshot write failures');
      final reachedWrite = Completer<void>(), releaseWrite = Completer<void>();
      store.debugBeforePageCommit = () async {
        if (!reachedWrite.isCompleted) reachedWrite.complete();
        await releaseWrite.future;
        throw StateError('Failed cache commit after identity change');
      };
      try {
        await openDirect('', false);
        await wait(find.byType(ChatTab));
        final cubit = tester.element(find.byType(ChatTab)).read<TeamCubit>();
        for (var i = 0; i < 180 && !reachedWrite.isCompleted; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 35)));
          await tester.pump(const Duration(milliseconds: 35));
        }
        expect(reachedWrite.isCompleted, isTrue);
        await tester.runAsync(() => auth.signInWithPassword(
            email: cfg['peerEmail'] as String, password: cfg['peerPassword'] as String));
        expect(auth.currentUser?.id, cfg['peerId']);
        releaseWrite.complete();
        for (var i = 0; i < 180 && !cubit.isClosed && cubit.state.chatRefreshing; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 35)));
          await tester.pump(const Duration(milliseconds: 35));
        }
        expect(cubit.isClosed || !cubit.state.chatRefreshing, isTrue);
        expect(cubit.state.chat.any((m) => m.id == ids['message']), isFalse);
        expect(find.text('QA subject discussion ${(ids['message'] as String).substring(0, 8)}'), findsNothing);
        print('PASS a failed cache commit finishing after a real account switch cannot publish the former owner\'s server page');
      } finally {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
        store.debugBeforePageCommit = null;
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      ProjectChatServerCache.qaInstance = null;
      await tester.runAsync(() => db.close());
      caps.dispose();
      await Supabase.instance.dispose();
      transport.close();
      return;
    }
    final subject =
        find.text('QA subject ${(ids['offering'] as String).substring(0, 8)}');
    await wait(subject);
    await tester.ensureVisible(subject.first);
    await tester.tap(subject.first);
    final action = find.text(offline ? 'Открыть чат' : 'Чат');
    await wait(action);
    await tester.ensureVisible(action.first);
    await tester.tap(action.first);
    await wait(find.byType(TeamDetailsScreen));
    if (ids['drafts'] == true) {
      Future<void> checkDraft(String id, String value) async {
        final editable = find.descendant(
            of: find.byType(TeamDetailsScreen),
            matching: find.byType(EditableText));
        await wait(editable);
        if (!offline) {
          await tester.enterText(editable.first, value);
          for (var n = 0; n < 100; n++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 35)));
            await tester.pump(const Duration(milliseconds: 35));
            final draft = await tester.runAsync(() => AccountDraftStore().read(
                'http://127.0.0.1:55321',
                auth.currentUser!.id,
                id,
                () => true));
            if (draft?['text'] == value) return;
          }
          fail('Draft was not saved through the ordinary composer');
        } else {
          for (var n = 0;
              n < 60 &&
                  tester.widget<EditableText>(editable.first).controller.text !=
                      value;
              n++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 30)));
            await tester.pump(const Duration(milliseconds: 35));
          }
          expect(tester.widget<EditableText>(editable.first).controller.text,
              value);
        }
      }

      await checkDraft(ids['team'] as String, 'My primary draft');
      final second = Team(
          id: ids['emptyTeam'] as String,
          name: 'Second group',
          teacher: '',
          groupCode: '',
          icon: '');
      await tester.pumpWidget(AuthSessionScopeHost(
          createScope: () => scope,
          child: MaterialApp(
              key: const ValueKey('second'),
              home: TeamDetailsScreen(
                  team: second,
                  cachedStore: offline ? store : null,
                  cachedCapabilities: offline ? caps : null,
                  cachedChatId: offline ? ids['emptyChat'] as String : null))));
      await checkDraft(ids['emptyTeam'] as String, 'My secondary draft');
      expect(transport.requests.isEmpty, offline);
      if (offline)
        print(
            'PASS 030 two independent group drafts restored from real on-disk Windows preferences without requests');
    } else if (ids['events'] == true) {
      final edited = find.text('Peer revised marker');
      final removed = find.text('Peer to remove marker');
      if (!offline) {
        await wait(removed);
        final peer = SupabaseClient(
            'http://127.0.0.1:55321', cfg['anonKey'] as String,
            httpClient: _Loopback(false),
            authOptions: const AuthClientOptions(autoRefreshToken: false));
        await tester.runAsync(() => peer.auth.signInWithPassword(
            email: cfg['peerEmail'] as String,
            password: cfg['peerPassword'] as String));
        expect(peer.auth.currentUser?.id, cfg['peerId']);
        // A real broadcast subscription receives the replica's committed events.
        await tester
            .runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
        await tester.runAsync(() => peer.rpc('edit_own_message', params: {
              'p_message_id': ids['eventEdit'],
              'p_text': 'Peer revised marker'
            }));
        await wait(edited);
        expect(find.text('Peer original marker'), findsNothing);
        await tester.runAsync(() => peer
            .from('messages')
            .delete()
            .eq('id', ids['eventDelete'] as String)
            .eq('author_id', cfg['peerId'] as String));
        for (var n = 0; n < 250 && removed.evaluate().isNotEmpty; n++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 32)));
          await tester.pump(const Duration(milliseconds: 32));
        }
        expect(removed, findsNothing);
        await tester.runAsync(peer.dispose);
        print('PASS live peer edit and deletion observed before restarting');
      } else {
        await wait(edited);
        expect(edited, findsOneWidget);
        expect(find.text('Peer original marker'), findsNothing);
        expect(removed, findsNothing);
        expect(transport.requests, isEmpty);
        print(
            'PASS 023 peer revision alone visible from SQLite in a new offline process');
        print(
            'PASS 024 confirmed deletion did not return from cache in a new offline process');
      }
    } else if (ids['ack'] == true) {
      final text = 'Confirmed outgoing ${ids['message']}';
      if (!offline) {
        final entry = find.descendant(
            of: find.byType(TeamDetailsScreen),
            matching: find.byType(EditableText)).hitTestable();
        await wait(entry);
        await tester.enterText(entry.first, text);
        await tester.pump();
        await tester.tap(find.byTooltip('Отправить'));
        final cubit = tester.element(entry.first).read<TeamCubit>();
        for (var n = 0;
            n < 160 &&
                !cubit.state.chat.any((m) =>
                    m.text == text &&
                    !m.isLocal &&
                    m.deliveryStatus == MessageDeliveryStatus.sent);
            n++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 18)));
          await tester.pump(const Duration(milliseconds: 18));
        }
        final sent = cubit.state.chat.singleWhere((m) =>
            m.text == text &&
            !m.isLocal &&
            m.deliveryStatus == MessageDeliveryStatus.sent);
        print('Server-confirmed outgoing displayed in chat pid=$pid');
        if (ids['crash'] == true) {
          File('$storage/confirmed-before-exit')
              .writeAsStringSync(sent.id, flush: true);
          exit(73);
        }
        final rows = await tester.runAsync(() => Supabase.instance.client
            .from('messages')
            .select('id')
            .eq('chat_id', ids['chat'] as String)
            .eq('body', text));
        expect(rows!.single['id'], sent.id);
      } else {
        await wait(find.text(text));
        expect(find.text(text), findsOneWidget);
        expect(transport.requests, isEmpty);
        print(
            'PASS 022 unique server-confirmed own message restored offline pid=$pid');
      }
    } else {
      final sixty = find.text('Sequence 60');
      final scroller = find.descendant(
          of: find.byType(TeamDetailsScreen), matching: find.byType(ListView));
      await wait(scroller);
      for (var step = 0;
          step < 50 && sixty.hitTestable().evaluate().isEmpty;
          step++) {
        await tester.drag(scroller.last, const Offset(0, 250));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await wait(sixty);
      await Scrollable.ensureVisible(tester.element(sixty.first),
          alignment: 0.5);
      await tester.pump(const Duration(milliseconds: 400));
      expect(sixty.hitTestable(), findsOneWidget);
      final position = tester.getCenter(sixty);
      final before = find.text('Sequence 59');
      final after = find.text('Sequence 61');
      expect(before, findsOneWidget);
      expect(after, findsOneWidget);
      expect(tester.getCenter(before).dy, lessThan(position.dy));
      expect(tester.getCenter(after).dy, greaterThan(position.dy));
      if (offline) {
        expect(transport.requests, isEmpty);
        print(
            'PASS 021 new process opened material and restored middle sequence 59, 60, 61 without HTTP in ${start.elapsedMilliseconds} ms; pid=$pid');
      } else {
        expect(transport.requests,
            contains('/rest/v1/rpc/get_chat_messages_page'));
        print(
            'PASS online real materials and 120-message server history, reached 59, 60, 61 in ${start.elapsedMilliseconds} ms; pid=$pid');
      }
      Future<void> back() async {
        await tester.binding.handlePopRoute();
        for (var n = 0; n < 8; n++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 40)));
          await tester.pump(const Duration(milliseconds: 45));
        }
      }

      await back();
      await back();
      final sort = find.text('Текущий семестр');
      await wait(sort);
      await tester.ensureVisible(sort.first);
      await tester.tap(sort.first);
      final sheet = find.byType(BottomSheet);
      await wait(sheet);
      final archived = find.descendant(of: sheet, matching: find.text('1'));
      await wait(archived);
      Future<void> tapVisible(Finder child) async {
        for (var frame = 0; frame < 20; frame++) {
          await tester.ensureVisible(child.first);
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 32)));
          await tester.pump(const Duration(milliseconds: 32));
          if (child.hitTestable().evaluate().isNotEmpty) break;
        }
        expect(child.hitTestable(), findsWidgets);
        await tester.tap(child.hitTestable().first);
      }

      await tapVisible(archived);
      await tapVisible(find.text('Показать предметы'));
      await wait(find.text('1-й семестр'));
      await tester.ensureVisible(subject.first);
      await tester.tap(subject.first);
      await wait(action);
      await tester.ensureVisible(action.first);
      await tester.tap(action.first);
      final sibling = find.text('Sibling source ${ids['chat']}');
      await wait(sibling);
      expect(sixty, findsNothing);
      if (offline)
        print(
            'PASS 027 same subject title in two semesters: both histories restored independently');
      if (!offline) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 570);
        await tester.binding.setSurfaceSize(const Size(390, 570));
      }
      await openDirect('empty', offline);
      await wait(find.text('Сообщений пока нет'));
      if (!offline) {
        expect(find.text('Написать'), findsNothing);
        expect(tester.getSize(find.byType(Scaffold).last).width, 390);
        final composer = find.byType(EditableText).last;
        await wait(composer);
        expect(composer.hitTestable(), findsOneWidget);
        await tester.tap(composer);
        await tester.pump();
        expect(tester.widget<EditableText>(composer).focusNode.hasFocus, isTrue);
        print('PASS 025 portrait 390x570 empty state has a single writing entry point');
        await tester.binding.setSurfaceSize(null);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
      if (offline) {
        print(
            'PASS 025 known empty conversation distinguished after process restart');
        await openDirect('cold', true);
        await wait(find.text('Сохранённые сообщения недоступны.'));
        expect(find.text('Сообщений пока нет'), findsNothing);
        expect(transport.requests, isEmpty);
        transport.offline = false;
        expect(
            caps.grant(SessionCapabilityMode.online,
                caps.beginAuthorization(scope.capture()!)!),
            isTrue);
        await openDirect('cold', false);
        await wait(find.text('Cold history marker'));
        print(
            'PASS 026 absent saved conversation on second process; real messages appear with connectivity and online route');
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    ProjectChatServerCache.qaInstance = null;
    await tester.runAsync(() => db.close());
    caps.dispose();

    await Supabase.instance.dispose();
    transport.close();
  }, skip: storage == null);
}
