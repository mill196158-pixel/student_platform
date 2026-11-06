import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/forward_payload.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/chats/forward/durable_forward_outbox.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_store.dart';
import 'package:student_platform/src/ui/chats/forward/forward_picker.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Storage implements ForwardOutboxStorage {
  final values = <String, String>{};
  @override Future<String?> read(String key) async => values[key];
  @override Future<bool> remove(String key) async { values.remove(key); return true; }
  @override Future<bool> write(String key, String value) async { values[key] = value; return true; }
}

class _Service implements IChatService {
  _Service(this.id, this.messages);
  final String id;
  final List<Message> messages;
  final sent = <String>[];
  bool failSend = false;
  final sentFileIds = <List<String>>[];
  @override ChatMode get mode => ChatMode.dm;
  @override bool get supportsAssignments => false;
  @override bool get supportsNotes => false;
  @override String get currentUserId => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  @override String? get chatId => id;
  @override Future<String> ensureChatId() async => id;
  @override List<Message> get currentMessages => messages;
  @override ChatMessagesViewState get messagesViewState => ChatMessagesViewState(
      phase: ChatMessagesLoadPhase.ready, messages: messages, hasSnapshot: true);
  @override Stream<ChatMessagesViewState> watchMessagesState() => Stream.value(messagesViewState);
  @override Stream<List<Message>> watchMessages() => Stream.value(messages);
  @override Future<Map<String, dynamic>> getUnreadMeta() async => {};
  @override Future<void> markRead(String lastMessageId) async {}
  @override Future<String> sendText(String text, {String? replyToId, List<String>? fileIds}) async {
    sent.add(text); sentFileIds.add(List.of(fileIds ?? const []));
    if (failSend) throw StateError('synthetic transport failure');
    return 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  }
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  sqfliteFfiInit();

  testWidgets('DM forward, cancel, unknown recovery and same-chat text forward', (tester) async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.llfbandit.app_links/events'), (call) async => null);
    await initializeDateFormatting('ru');
    late AuthSessionScope scope;
    Session? scopeSession;
    late Directory dir;
    late Database db;
    const uid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await tester.runAsync(() async {
    await Supabase.initialize(url: 'https://example.invalid', publishableKey: 'test',
        httpClient: MockClient((request) async => http.Response('[]', 200,
            request: request, headers: {'content-type': 'application/json'})),
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    final client = Supabase.instance.client;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${part({'alg': 'none'})}.${part({'sub': uid, 'session_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'iat': now, 'exp': now + 3600})}.sig';
    await client.auth.setInitialSession(jsonEncode({'access_token': token, 'refresh_token': 'test', 'token_type': 'bearer', 'expires_at': now + 3600,
      'user': {'id': uid, 'aud': 'authenticated', 'app_metadata': {}, 'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}}));
    scopeSession = client.auth.currentSession;
    scope = AuthSessionScope(currentSession: () => scopeSession, authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    dir = await Directory.systemTemp.createTemp('dm_widget_qa_');
    db = await openDurableForwardDatabase('${dir.path}/outbox.db', factory: databaseFactoryFfi);
    });
    const oldFileId = '33333333-3333-4333-8333-333333333333';
    const copiedFileId = '44444444-4444-4444-8444-444444444444';
    final source = _Service('source', [Message(id: 'm1', chatId: 'source', authorId: uid,
      authorLogin: 'test', authorName: 'Автор', text: 'Проверка пересылки', at: DateTime.utc(2026),
      attachments: [ChatFile(id: oldFileId, chatId: 'source', messageId: 'm1',
          fileName: 'source.pdf', fileKey: 'source.pdf', fileUrl: 'https://example.invalid/source.pdf',
          fileType: 'application/pdf', fileSize: 100, uploadedBy: 'other-user', uploadedAt: DateTime.utc(2026))])]);
    final target = _Service('target', [Message(id: 'target-msg', chatId: 'target', authorId: uid,
        authorLogin: 'test', authorName: 'Автор', text: 'Новое сообщение', at: DateTime.utc(2026))]);
    final navigator = GlobalKey<NavigatorState>();
    var sameChat = false;
    final cancelCommitted = Completer<void>(), cancelRelease = Completer<void>();
    final unknownCancelled = Completer<void>(), releaseUnknown = Completer<void>();
    var copies = 0;
    Future<ForwardFileRef> copyFile(ForwardFileRef file, String destination) async {
      expect(file.id, oldFileId);
      expect(destination, sameChat ? 'source' : 'target');
      copies++;
      return const ForwardFileRef(id: copiedFileId, url: 'https://example.invalid/copied.pdf',
          name: 'source.pdf', type: 'application/pdf', size: 100);
    }
    final storage = _Storage();
    Future<void> tapSendWhenVisible() async {
      final send = find.byTooltip('Отправить');
      for (var i = 0; i < 80 && send.hitTestable().evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(send.hitTestable(), findsOneWidget);
      await tester.tap(send.hitTestable());
    }
    await tester.pumpWidget(ForwardOutboxHost(source: scope, storage: storage, durableMode: true,
      openDatabaseOverride: () async => db, backendOverride: 'qa-backend',
      child: MaterialApp(navigatorKey: navigator, home: UnifiedChatScreen(service: source, title: 'Источник', debugCopyForwardFile: copyFile,
        debugAfterDurableCancel: () async { unknownCancelled.complete(); await releaseUnknown.future; },
        debugPickForwardTarget: (context, current) async =>
        ForwardTarget(chatId: sameChat ? 'source' : 'target', title: 'Получатель', mode: ChatMode.dm,
          open: (context) async { await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UnifiedChatScreen(
            service: target, title: 'Получатель', debugCopyForwardFile: copyFile,
            debugPickForwardTarget: (_, __) async => ForwardTarget(chatId: 'target', title: 'Этот чат', mode: ChatMode.dm, open: (_) async {}),
            debugAfterDurableCancel: () async { if (!cancelCommitted.isCompleted) cancelCommitted.complete(); await cancelRelease.future; },
          ))); })))));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Проверка пересылки'), findsOneWidget);
    await tester.longPress(find.text('Проверка пересылки'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Получатель'), findsWidgets);
    expect(target.sent, isEmpty);
    expect(find.byTooltip('Отменить пересылку'), findsOneWidget);
    await tester.tap(find.byTooltip('Отменить пересылку'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Удалить сохранённую пересылку?'), findsOneWidget);
    await tester.tap(find.text('Удалить').last);
    for (var i = 0; i < 15 && !cancelCommitted.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(cancelCommitted.isCompleted, isTrue);
    await tester.longPress(find.text('Новое сообщение'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    cancelRelease.complete();
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byTooltip('Отменить пересылку'), findsNothing);
    await tester.runAsync(() async {
      final durable = DurableForwardOutbox(db, scope, 'qa-backend');
      final newer = await durable.peek(scope.capture()!, 'target');
      expect(newer, isNotNull);
      expect(ForwardPayload.tryParse(newer!.source)!.items.single.text, 'Новое сообщение');
      expect(await durable.terminalOperations(scope.capture()!, 'target'), hasLength(1));
      await durable.cancelByUser(newer);
    });
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() async {
      final durable = DurableForwardOutbox(db, scope, 'qa-backend');
      final payload = ForwardPayload(fromChatId: 'source', items: [ForwardItem(messageId: 'm2', authorId: uid,
          authorName: 'Автор', at: DateTime.utc(2026), text: 'Возможная отправка', files: const [])]).encodeForText();
      final reserved = await durable.reserve(scope.capture()!, 'target', source: payload, sourceUrls: [], sourceIds: []);
      final queued = await durable.confirmReservation(reserved);
      final preparing = await durable.markPreparing(queued);
      final ready = await durable.markReady(preparing, prepared: payload, preparedIds: [], uploadedIdsBySource: {});
      await durable.markSending(ready, text: payload, replyId: null, fileIds: []);
    });
    unawaited(navigator.currentState!.push(MaterialPageRoute(builder: (_) => UnifiedChatScreen(service: target, title: 'Получатель'))));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Отправка не подтверждена'), findsOneWidget);
    expect(find.text('Повторить'), findsNothing);
    expect(target.sent, isEmpty);
    await tester.tap(find.text('Проверить чат'));
    await tester.pump(const Duration(milliseconds: 300));
    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 300));
    sameChat = true;
    await tester.longPress(find.text('Проверка пересылки'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byTooltip('Отменить пересылку'), findsOneWidget);
    await tapSendWhenVisible();
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(source.sent, hasLength(1));
    expect(ForwardPayload.tryParse(source.sent.single)!.fromChatId, 'source');
    expect(source.sentFileIds.single, [copiedFileId]);
    expect(source.sentFileIds.single, isNot(contains(oldFileId)));
    expect(copies, 2);
    source.failSend = true;
    await tester.longPress(find.text('Проверка пересылки'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tapSendWhenVisible();
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Отправка пересылки не подтверждена. Проверьте чат перед повтором.'), findsOneWidget);
    expect(source.sent, hasLength(2));
    await tester.runAsync(() async {
      final durable = DurableForwardOutbox(db, scope, 'qa-backend');
      final unknown = await durable.peek(scope.capture()!, 'source');
      expect(unknown?.state, DurableForwardState.sendingUnknown);
    });
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Отправить'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Отправка не подтверждена'), findsOneWidget);
    await tester.tap(find.text('Удалить пересылку'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Сообщение уже могло быть отправлено'), findsOneWidget);
    await tester.tap(find.text('Удалить').last);
    for (var i = 0; i < 10 && !unknownCancelled.isCompleted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(unknownCancelled.isCompleted, isTrue);
    await tester.enterText(find.byType(TextField).last, 'Новый черновик');
    releaseUnknown.complete();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() async {
      final durable = DurableForwardOutbox(db, scope, 'qa-backend');
      expect(await durable.peek(scope.capture()!, 'source'), isNull);
    });
    expect(source.sent, hasLength(2));
    expect(find.text('Новый черновик'), findsOneWidget);
    final legacyKey = 'forward_outbox_${uid}_source';
    final legacyRaw = jsonEncode({'text': 'old legacy', 'files': [], 'file_ids': []});
    storage.values[legacyKey] = legacyRaw;
    source.failSend = false;
    unawaited(navigator.currentState!.push(MaterialPageRoute(builder: (_) => UnifiedChatScreen(service: source, title: 'Источник'))));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, 'Обычное сообщение');
    await tester.tap(find.byTooltip('Отправить').last);
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(source.sent.last, 'Обычное сообщение');
    expect(storage.values[legacyKey], legacyRaw);
    await tester.enterText(find.byType(TextField).last, '__FG__:not-valid');
    await tester.tap(find.byTooltip('Отправить').last);
    await tester.pump(const Duration(milliseconds: 200));
    expect(source.sent, hasLength(3));
    expect(storage.values[legacyKey], legacyRaw);
    ScaffoldMessenger.of(tester.element(find.byType(TextField).last)).clearSnackBars();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, '{"forward":{"items":[]}}');
    await tester.tap(find.byTooltip('Отправить').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(source.sent, hasLength(3));
    expect(storage.values[legacyKey], legacyRaw);
    ScaffoldMessenger.of(tester.element(find.byType(TextField).last)).clearSnackBars();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).last, '{"from_chat_id":"other"}');
    await tester.tap(find.byTooltip('Отправить').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(source.sent, hasLength(3));
    expect(storage.values[legacyKey], legacyRaw);
    ScaffoldMessenger.of(tester.element(find.byType(TextField).last)).clearSnackBars();
    await tester.pump(const Duration(milliseconds: 300));
    final old = scopeSession!;
    scopeSession = Session(accessToken: 'new-credential-without-event',
        refreshToken: 'new-refresh', tokenType: 'bearer', user: old.user);
    await tester.enterText(find.byType(TextField).last, 'Не отправлять после смены сессии');
    await tester.tap(find.byTooltip('Отправить').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(source.sent, hasLength(3));
    expect(storage.values[legacyKey], legacyRaw);
    await tester.pumpWidget(const SizedBox.shrink());
    scopeSession = old;
    var unsupportedCalls = 0, picks = 0;
    await tester.pumpWidget(ForwardOutboxHost(source: scope, storage: storage, durableMode: true,
      openDatabaseOverride: () async { unsupportedCalls++; throw UnsupportedError('QA unsupported'); },
      backendOverride: 'qa-backend', child: MaterialApp(home: UnifiedChatScreen(
        service: source, title: 'Источник', debugPickForwardTarget: (_, __) async {
          picks++;
          return ForwardTarget(chatId: 'target', title: 'Получатель', mode: ChatMode.dm, open: (_) async {});
        }))));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.longPress(find.text('Проверка пересылки'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Выбрать').last);
    await tester.pumpAndSettle();
    expect(find.text('Выбрано 1'), findsOneWidget);
    for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(unsupportedCalls, greaterThan(0));
    expect(picks, greaterThan(0));
    expect(find.text('Выбрано 1'), findsOneWidget);
    expect(storage.values[legacyKey], legacyRaw);
    expect(source.sent, hasLength(3));
    await tester.pumpWidget(const SizedBox.shrink());
    final legacyStorage = _Storage();
    var legacyPicker = 0, legacyOpened = 0;
    await tester.pumpWidget(ForwardOutboxHost(source: scope, storage: legacyStorage,
      child: MaterialApp(home: UnifiedChatScreen(service: source, title: 'Источник',
        debugPickForwardTarget: (_, __) async {
          legacyPicker++;
          return ForwardTarget(chatId: 'legacy-target', title: 'Получатель', mode: ChatMode.dm,
            open: (_) async { legacyOpened++; });
        }))));
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.longPress(find.text('Проверка пересылки'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Выбрать').last);
    await tester.pumpAndSettle();
    for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
      messenger.clearSnackBars();
      messenger.removeCurrentSnackBar();
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переслать').last);
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(legacyPicker, 1);
    expect(legacyOpened, 1);
    expect(legacyStorage.values['forward_outbox_${uid}_legacy-target'], isNotNull);
    expect(source.sent, hasLength(3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      scope.dispose();
      await Supabase.instance.dispose();
      if (db.isOpen) await db.close();
      final root = await Directory.systemTemp.resolveSymbolicLinks();
      final path = await dir.resolveSymbolicLinks();
      if (!p.isWithin(root, path) || !p.basename(path).startsWith('dm_widget_qa_')) throw StateError('Unsafe QA path');
      for (var i = 0; i < 20 && await dir.exists(); i++) {
        try { await dir.delete(recursive: true); }
        on FileSystemException { await Future<void>.delayed(const Duration(milliseconds: 50)); }
      }
      expect(await dir.exists(), isFalse);
    });
  });
}
