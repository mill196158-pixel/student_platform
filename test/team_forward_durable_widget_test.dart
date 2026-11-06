import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/forward/durable_forward_outbox.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:student_platform/src/ui/chats/forward/forward_picker.dart';
import 'package:student_platform/src/ui/learning/data/learning_repository.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat_tab.dart';
import 'package:student_platform/src/ui/learning/global_cache.dart';
import 'package:student_platform/src/ui/learning/account_draft_store.dart';
import 'package:student_platform/src/ui/learning/draft_recovery_journal.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Storage implements ForwardOutboxStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> write(String key, String value) async {
    values[key] = value;
    return true;
  }
}

class _DelayedDraftPreferences extends InMemorySharedPreferencesStore {
  _DelayedDraftPreferences() : super.empty();
  bool armed = false;
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (armed && key.startsWith('flutter.account_draft_v1_')) {
      armed = false;
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    return super.setValue(type, key, value);
  }
}

class _Repo implements LearningRepository {
  final sentTexts = <String>[];
  Completer<String?>? pendingSave;
  @override
  Future<String?> saveChat(String teamId, List<Message> messages) async {
    sentTexts.addAll(messages.map((message) => message.text));
    if (pendingSave != null) return pendingSave!.future;
    return 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  }
  @override
  Future<Message?> loadMessageById(String teamId, String messageId) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows)
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  sqfliteFfiInit();

  testWidgets('team forward copies an attachment into the durable composer',
      (tester) async {
    final originalPreferences = SharedPreferencesStorePlatform.instance;
    final delayedPreferences = _DelayedDraftPreferences();
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = delayedPreferences;
    addTearDown(() {
      if (!delayedPreferences.release.isCompleted) delayedPreferences.release.complete();
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = originalPreferences;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/events'),
            (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('keyboard_image_channel'),
            (call) async => null);
    await initializeDateFormatting('ru');
    late AuthSessionScope scope;
    late Directory dir;
    late Database db;
    var sent = 0;
    Completer<void>? pauseFileSend;
    var copies = 0;
    List<dynamic>? sentFileIds;
    const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const chat = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    await tester.runAsync(() async {
      await Supabase.initialize(
          url: SupabaseConfig.url,
          publishableKey: 'test',
          httpClient: MockClient((request) async {
            if (request.url.host != Uri.parse(SupabaseConfig.url).host)
              throw StateError('Unexpected test network target');
            if (request.url.path
                .endsWith('/rpc/send_chat_message_with_files')) {
              sent++;
              sentFileIds = (jsonDecode(request.body)
                  as Map<String, dynamic>)['p_file_ids'] as List<dynamic>?;
              if (pauseFileSend != null) await pauseFileSend.future;
              return http.Response(
                  '"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"', 200,
                  request: request,
                  headers: {'content-type': 'application/json'});
            }
            final body =
                request.url.path.endsWith('/chats') ? '{"id":"$chat"}' : '[]';
            return http.Response(body, 200,
                request: request,
                headers: {'content-type': 'application/json'});
          }),
          authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
      final client = Supabase.instance.client;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      String part(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final token = '${part({'alg': 'none'})}.${part({
            'sub': uid,
            'iss': '${SupabaseConfig.url}/auth/v1',
            'aud': 'authenticated',
            'role': 'authenticated',
            'session_id': 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            'iat': now,
            'exp': now + 3600
          })}.sig';
      await client.auth.setInitialSession(jsonEncode({
        'access_token': token,
        'refresh_token': 'test',
        'token_type': 'bearer',
        'expires_at': now + 3600,
        'user': {
          'id': uid,
          'aud': 'authenticated',
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-01-01T00:00:00Z'
        }
      }));
      scope = AuthSessionScope(
          currentSession: () => client.auth.currentSession,
          authEvents: client.auth.onAuthStateChange);
      await scope.ready;
      dir = await Directory.systemTemp.createTemp('team_widget_qa_');
      db = await openDurableForwardDatabase(p.join(dir.path, 'outbox.db'),
          factory: databaseFactoryFfi);
      DraftRecoveryJournal.debugOpen = () async => db;
      await DraftRecoveryJournal().append(project: SupabaseConfig.url, owner: uid,
          sessionId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          conversation: '11111111-1111-4111-8111-111111111111',
          draft: {'text': 'Резервный черновик', 'files': [], 'reply': null},
          permitted: () => true);
    });
    const team = Team(
        id: '11111111-1111-4111-8111-111111111111',
        name: 'Команда',
        teacher: '',
        groupCode: '',
        icon: 'К');
    final repo = _Repo();
    final cubit = TeamCubit(team, repository: repo);
    final message = Message(
        id: '22222222-2222-4222-8222-222222222222',
        chatId: chat,
        authorId: uid,
        authorLogin: 'test',
        authorName: 'Автор',
        text: 'Сообщение для пересылки',
        attachments: [
          ChatFile(
              id: '33333333-3333-4333-8333-333333333333',
              chatId: chat,
              messageId: '22222222-2222-4222-8222-222222222222',
              fileName: 'source.pdf',
              fileKey: 'source.pdf',
              fileUrl: 'https://example.invalid/source.pdf',
              fileType: 'application/pdf',
              fileSize: 100,
              uploadedBy: 'other-user',
              uploadedAt: DateTime.utc(2026))
        ],
        at: DateTime.utc(2026));
    cubit.emit(TeamState(team: team, chat: [message], chatHasSnapshot: true));
    final storage = _Storage();
    final legacyModeStorage = _Storage();
    final cancelEntered = Completer<void>();
    final releaseCancel = Completer<void>();
    var pauseFirstCancel = true;
    Future<Database> openDb() async => db;
    var unsupportedCalls = 0;
    var picks = 0;
    Future<Database> unsupportedDb() async {
      unsupportedCalls++;
      throw UnsupportedError('QA unsupported');
    }
    Widget app(Key key, {bool unsupported = false, bool durable = true}) => ForwardOutboxHost(
        source: scope,
        storage: durable ? storage : legacyModeStorage,
        durableMode: durable,
        openDatabaseOverride: unsupported ? unsupportedDb : openDb,
        backendOverride: 'qa-backend',
        child: AuthSessionScopeHost(child: MaterialApp(
            home: BlocProvider.value(
                value: cubit,
                child: Scaffold(
                    body: ChatTab(
                        key: key,
                        debugAfterDurableCancel: () async {
                          if (!pauseFirstCancel) return;
                          pauseFirstCancel = false;
                          cancelEntered.complete();
                          await releaseCancel.future;
                        },
                        copyForwardFileOverride: (source, targetChat) async {
                          expect(source.id,
                              '33333333-3333-4333-8333-333333333333');
                          expect(targetChat, chat);
                          copies++;
                          return const ForwardFileRef(
                              id: '44444444-4444-4444-8444-444444444444',
                              url: 'https://example.invalid/new.pdf',
                              name: 'source.pdf',
                              type: 'application/pdf',
                              size: 100);
                        },
                        forwardTargetOverride: () async {
                          picks++;
                          return ForwardTarget(
                            chatId: chat,
                            title: 'Команда',
                            mode: ChatMode.team,
                            open: (_) async {});
                        }))))));
    await GlobalCache().saveDraft(team.id, 'Прежний черновик', []);
    await tester.pumpWidget(app(const ValueKey('initial')));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Сообщение для пересылки'), findsWidgets);
    expect(find.text('Восстановить прежний черновик'), findsOneWidget);
    await tester.tap(find.text('Восстановить прежний черновик'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Прежний черновик'), findsOneWidget);
    expect(GlobalCache().getDraft(team.id)?.$1, 'Прежний черновик');
    await tester.enterText(find.byType(TextField).last, 'Новый текст');
    expect(find.text('Восстановить несохранённый черновик'), findsOneWidget);
    await tester.tap(find.text('Восстановить несохранённый черновик'));
    await tester.pump();
    expect(find.text('Новый текст'), findsOneWidget);
    expect(find.text('Сначала сохраните или очистите текущий черновик.'), findsOneWidget);
    for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
    }
    await tester.enterText(find.byType(TextField).last, '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Восстановить несохранённый черновик'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('Резервный черновик'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    final hydrationStore = AccountDraftStore();
    await tester.enterText(find.byType(TextField).last, 'Старый scoped');
    await tester.pump(const Duration(milliseconds: 400));
    final hydrationEntered = Completer<void>();
    final hydrationRelease = Completer<void>();
    AccountDraftStore.debugBeforeRead = () async {
      if (!hydrationEntered.isCompleted) hydrationEntered.complete();
      await hydrationRelease.future;
    };
    addTearDown(() {
      AccountDraftStore.debugBeforeRead = null;
      if (!hydrationRelease.isCompleted) hydrationRelease.complete();
    });
    await tester.pumpWidget(app(const ValueKey('early-input')));
    for (var i = 0; i < 20 && !hydrationEntered.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(hydrationEntered.isCompleted, isTrue);
    expect(find.byType(TextField), findsWidgets,
        reason: 'composer remains visible while scoped draft loads');
    await tester.enterText(find.byType(TextField).last, 'Новый ранний ввод');
    hydrationRelease.complete();
    AccountDraftStore.debugBeforeRead = null;
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Новый ранний ввод'), findsOneWidget);
    final hydrationSaved = await hydrationStore.read(SupabaseConfig.url, uid, team.id, () => true);
    expect(hydrationSaved?['text'], 'Новый ранний ввод');
    expect((hydrationSaved?['previous'] as Map)['text'], 'Старый scoped');
    await tester.enterText(find.byType(TextField).last, '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Восстановить сохранённый черновик'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Старый scoped'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField).last, 'Старый до ошибки');
    await tester.pump(const Duration(milliseconds: 400));
    AccountDraftStore.debugBeforeRead = () async => throw TimeoutException('synthetic');
    await tester.pumpWidget(app(const ValueKey('read-error')));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Черновик пока не сохраняется. Повторить'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Новый при ошибке');
    AccountDraftStore.debugBeforeRead = null;
    await tester.tap(find.text('Черновик пока не сохраняется. Повторить'));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Новый при ошибке'), findsOneWidget);
    final afterError = await hydrationStore.read(SupabaseConfig.url, uid, team.id, () => true);
    expect(afterError?['text'], 'Новый при ошибке');
    expect((afterError?['previous'] as Map)['text'], 'Старый до ошибки');
    await tester.enterText(find.byType(TextField).last, '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Восстановить сохранённый черновик'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Старый до ошибки'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.longPress(find.text('Сообщение для пересылки').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final rows = await tester
        .runAsync(() => db.rawQuery('SELECT state FROM forward_item'));
    expect(rows!.single['state'], 'ready');
    expect(sent, 0);
    await tester.tap(find.byTooltip('Отменить пересылку'));
    for (var i = 0; i < 30 && !cancelEntered.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cancelEntered.isCompleted, isTrue);
    await tester.longPress(find.text('Сообщение для пересылки').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final canceled = await tester
        .runAsync(() => db.rawQuery('SELECT kind FROM forward_terminal'));
    expect(canceled!.single['kind'], 'canceled');
    final newer = await tester
        .runAsync(() => db.rawQuery('SELECT state FROM forward_item'));
    expect(newer, hasLength(1));
    releaseCancel.complete();
    for (var i = 0; i < 20 && find.byTooltip('Отменить пересылку').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byTooltip('Отменить пересылку'), findsNothing);
    expect(
        await tester
            .runAsync(() => db.rawQuery('SELECT state FROM forward_item')),
        hasLength(1));
    await tester.pumpWidget(app(const ValueKey('after-cancel')));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Проверить пересылку'), findsOneWidget);
    await tester.tap(find.text('Подготовить'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
        (await tester
                .runAsync(() => db.rawQuery('SELECT state FROM forward_item')))!
            .single['state'],
        'ready');
    await tester.pump(const Duration(seconds: 5));
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first).clearSnackBars();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Отправить'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(sent, 1);
    expect(copies, 2);
    expect(sentFileIds, ['44444444-4444-4444-8444-444444444444']);
    expect(
        await tester
            .runAsync(() => db.rawQuery('SELECT state FROM forward_item')),
        isEmpty);
    final terminals = await tester
        .runAsync(() => db.rawQuery('SELECT kind FROM forward_terminal'));
    expect(terminals!.map((row) => row['kind']).toSet(), {'canceled', 'sent'});

    await tester.runAsync(() async {
      final outbox = DurableForwardOutbox(db, scope, 'qa-backend');
      final payload = ForwardPayload(fromChatId: chat, items: [
        ForwardItem(
            messageId: 'm',
            authorId: uid,
            authorName: 'Автор',
            at: DateTime.utc(2026),
            text: 'неизвестно',
            files: const [])
      ]).encodeForText();
      final reserved = await outbox.reserve(scope.capture()!, chat,
          source: payload, sourceUrls: [], sourceIds: []);
      final queued = await outbox.confirmReservation(reserved);
      final preparing = await outbox.markPreparing(queued);
      final ready = await outbox.markReady(preparing,
          prepared: payload, preparedIds: [], uploadedIdsBySource: {});
      await outbox
          .markSending(ready, text: payload, replyId: null, fileIds: []);
    });
    await tester.pumpWidget(app(const ValueKey('reopen')));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Отправка не подтверждена'), findsOneWidget);
    expect(sent, 1);
    await tester.tap(find.text('Проверить чат'));
    await tester.pump();
    expect(sent, 1);
    final legacyKey = 'forward_outbox_${uid}_$chat';
    final legacyRaw = jsonEncode({'text': 'legacy QA', 'files': [], 'file_ids': []});
    storage.values[legacyKey] = legacyRaw;
    await tester.pumpWidget(app(const ValueKey('legacy')));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.enterText(find.byType(TextField).last, 'Обычный текст QA');
    await tester.pump(const Duration(seconds: 5));
    for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Отправить'));
    for (var i = 0; i < 20 && repo.sentTexts.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(repo.sentTexts, ['Обычный текст QA']);
    expect(storage.values[legacyKey], legacyRaw);
    expect(sent, 1);
    // While the first message is in flight the user may start the next one.
    // Its contents must survive both the RPC and the draft cleanup.
    repo.pendingSave = Completer<String?>();
    await tester.enterText(find.byType(TextField).last, 'Первое сообщение');
    await tester.pump();
    await tester.tap(find.byTooltip('Отправить'));
    for (var i = 0; i < 20 && repo.sentTexts.length < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(repo.sentTexts.last, 'Первое сообщение');
    await tester.enterText(find.byType(TextField).last, 'Следующий черновик');
    await tester.pump(const Duration(milliseconds: 400));
    repo.pendingSave!.complete('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    repo.pendingSave = null;
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Следующий черновик'), findsOneWidget);
    final accountDraft = AccountDraftStore();
    expect((await accountDraft.read(SupabaseConfig.url, uid, team.id, () => true))?['text'], 'Следующий черновик');
    repo.pendingSave = Completer<String?>();
    await tester.enterText(find.byType(TextField).last, 'Сообщение без подтверждения');
    await tester.pump();
    await tester.tap(find.byTooltip('Отправить'));
    for (var i = 0; i < 20 && repo.sentTexts.length < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(repo.sentTexts.last, 'Сообщение без подтверждения');
    repo.pendingSave!.complete(null);
    repo.pendingSave = null;
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Сообщение без подтверждения'), findsWidgets);
    expect((await accountDraft.read(SupabaseConfig.url, uid, team.id, () => true))?['text'], 'Сообщение без подтверждения');
    await tester.enterText(find.byType(TextField).last, '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    cubit.emit(TeamState(team: team, chat: [message], chatHasSnapshot: true));
    await tester.pumpWidget(const SizedBox.shrink());
    await accountDraft.write(SupabaseConfig.url, uid, team.id, {'text': 'Файл', 'files': [{
      'localId': 'sent-local', 'path': '/test/sent.pdf', 'name': 'sent.pdf',
      'mimeType': 'application/pdf', 'size': 100, 'isImage': false,
      'uploadedFileId': '44444444-4444-4444-8444-444444444444',
    }], 'reply': null}, () => true);
    await tester.pumpWidget(app(const ValueKey('file-race')));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('sent.pdf'), findsWidgets);
    pauseFileSend = Completer<void>();
    for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Отправить'));
    for (var i = 0; i < 20 && sent < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(sent, 2);
    tester.widget<ChatComposerBar>(find.byType(ChatComposerBar)).onAddFile(AttachedFile(
      localId: 'new-local', path: '/test/new.pdf', name: 'new.pdf',
      isImage: false, size: 120));
    await tester.pump();
    await tester.longPress(find.text('Сообщение для пересылки').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Ответить').last);
    await tester.pump();
    expect(tester.widget<ChatComposerBar>(find.byType(ChatComposerBar)).replyTo?.id,
        message.id);
    pauseFileSend.complete();
    pauseFileSend = null;
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('new.pdf'), findsWidgets);
    expect(tester.widget<ChatComposerBar>(find.byType(ChatComposerBar)).replyTo?.id,
        message.id);
    final savedDraft = await accountDraft.read(SupabaseConfig.url, uid, team.id, () => true);
    final savedFiles = savedDraft?['files'] as List;
    expect(savedFiles.map((f) => f['name']), contains('new.pdf'));
    expect(savedFiles.map((f) => f['name']), isNot(contains('sent.pdf')));
    expect((savedDraft?['reply'] as Map)['id'], message.id);
    await tester.pumpWidget(const SizedBox.shrink());
    await accountDraft.write(SupabaseConfig.url, uid, team.id,
        {'text': '', 'files': [], 'reply': null}, () => true);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(const ValueKey('unsupported'), unsupported: true));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.longPress(find.text('Сообщение для пересылки').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Выбрать').last);
    await tester.pumpAndSettle();
    expect(find.text('Выбрано 1'), findsOneWidget);
    for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
    }
    await tester.pumpAndSettle();
    final picksBeforeUnsupportedForward = picks;
    await tester.tap(find.text('Переслать').last, warnIfMissed: true);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(unsupportedCalls, greaterThan(0));
    expect(picks, greaterThan(picksBeforeUnsupportedForward));
    expect(find.text('Выбрано 1'), findsOneWidget);
    expect(storage.values[legacyKey], legacyRaw);
    expect(sent, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(const ValueKey('legacy-mode'), durable: false));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.longPress(find.text('Сообщение для пересылки').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byTooltip('Отменить пересылку'), findsOneWidget);
    expect(sent, 2); // Only staging was checked; no legacy-mode send.
    await tester.pumpWidget(const SizedBox.shrink());
    final incomplete = Message(
      id: 'incomplete-message', chatId: chat, authorId: uid,
      authorLogin: 'test', authorName: 'Автор', text: 'Неполное вложение',
      at: DateTime.utc(2026), fileId: '33333333-3333-4333-8333-333333333333',
    );
    cubit.emit(TeamState(team: team, chat: [incomplete], chatHasSnapshot: true));
    final picksBeforeIncomplete = picks, sendsBeforeIncomplete = sent;
    await tester.pumpWidget(app(const ValueKey('incomplete')));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.longPress(find.text('Неполное вложение').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Выбрать').last);
    await tester.pumpAndSettle();
    for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переслать').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('вложений ещё недоступна'), findsOneWidget);
    expect(find.text('Выбрано 1'), findsOneWidget);
    expect(picks, picksBeforeIncomplete);
    expect(sent, sendsBeforeIncomplete);
    cubit.emit(TeamState(team: team, chat: [message], chatHasSnapshot: true));
    await tester.pumpWidget(app(const ValueKey('account-race-a1')));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    delayedPreferences.armed = true;
    await tester.enterText(find.byType(TextField).last, 'Первый A');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => delayedPreferences.started.future);
    final client = Supabase.instance.client;
    final oldSessionJson = client.auth.currentSession!.toJson();
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String encoded(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    const otherUid = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    final otherToken = '${encoded({'alg': 'none'})}.${encoded({
      'iss': '${SupabaseConfig.url}/auth/v1', 'sub': otherUid,
      'session_id': 'ffffffff-ffff-4fff-8fff-ffffffffffff',
      'aud': 'authenticated', 'role': 'authenticated', 'iat': now, 'exp': now + 3600,
    })}.sig';
    await tester.runAsync(() => client.auth.setInitialSession(jsonEncode({
      'access_token': otherToken, 'refresh_token': 'other', 'token_type': 'bearer',
      'expires_at': now + 3600, 'user': {'id': otherUid, 'aud': 'authenticated',
        'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'},
    })));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Первый A'), findsNothing);
    expect(await accountDraft.read(SupabaseConfig.url, otherUid, team.id, () => true), isNull);
    await tester.runAsync(() => client.auth.setInitialSession(jsonEncode(oldSessionJson)));
    await tester.pumpWidget(app(const ValueKey('account-race-a2')));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.enterText(find.byType(TextField).last, 'Новый A');
    delayedPreferences.release.complete();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Новый A'), findsOneWidget);
    final afterSwitch = await accountDraft.read(SupabaseConfig.url, uid, team.id, () => true);
    expect(afterSwitch?['text'], 'Новый A');
    expect((afterSwitch?['previous'] as Map)['text'], 'Первый A');
    await tester.pumpWidget(const SizedBox.shrink());
    await cubit.close();
    scope.dispose();
    DraftRecoveryJournal.debugOpen = null;
    await tester.runAsync(() async {
      if (db.isOpen) await db.close();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final target = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, target)) throw StateError('Invalid QA directory');
      // Windows may release the SQLite file handle just after close completes.
      for (var attempt = 0;; attempt++) {
        try {
          await dir.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 19) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
  });
}
