import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/learning/models/chat_file.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ordinary initializer restores saved SDK session and opens saved chat offline', (tester) async {
    if (Platform.isWindows) open.overrideFor(OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    sqfliteFfiInit();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('ordinary_real_init_')))!;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/events'), (_) async => null);
    final now = DateTime.now().toUtc();
    final project = SupabaseConfig.url.replaceFirst(RegExp(r'/$'), '');
    const uid = 'init-owner', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final token = '${part({'alg': 'HS256'})}.${part({
      'iss': '$project/auth/v1', 'sub': uid, 'session_id': sid,
      'role': 'authenticated', 'aud': 'authenticated',
      'iat': now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
    })}.sig';
    final raw = jsonEncode({'access_token': token, 'refresh_token': 'synthetic',
      'token_type': 'bearer', 'expires_in': 3600,
      'expires_at': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      'user': {'id': uid, 'aud': 'authenticated', 'app_metadata': {},
        'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'}});
    final session = Session.fromJson(jsonDecode(raw))!;
    final events = StreamController<AuthState>.broadcast(sync: true);
    final priorScope = AuthSessionScope(currentSession: () => session, authEvents: events.stream);
    events.add(AuthState(AuthChangeEvent.initialSession, session));
    final savedBinding = OfflineSessionBinding.fromSession(session, '$project/auth/v1')!;
    SharedPreferences.setMockInitialValues({
      'sb-${Uri.parse(project).host.split('.').first}-auth-token': raw,
    });
    final home = HomeSnapshotCache(project: project, authScope: priorScope,
      currentUserId: () => priorScope.capture()?.userId, sessionGeneration: () => priorScope.generation,
      sessionIdentity: priorScope.capture);
    final homeScope = home.captureScope(uid)!;
    final db = (await tester.runAsync(() => openProjectChatServerDatabase(
      '${dir.path}/offline_chat_ordinary_v1.db', factory: databaseFactoryFfi)))!;
    final cache = ProjectChatServerCache(db: db, scope: priorScope,
      currentBinding: () => savedBinding, project: project);
    final bytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII=');
    await tester.runAsync(() async {
      expect(await home.write(scope: homeScope, section: HomeSnapshotSection.profile,
        items: [{'id': uid, 'name': 'Студент запуска'}], savedAt: now), isTrue);
      final summary = (await cache.begin(ProjectChatServerCache.summaryChatKey))!;
      expect(await cache.saveSummaries(summary, [{
        'team': {'id': '', 'name': 'Друг', 'teacher': '', 'groupCode': '', 'icon': ''},
        'title': 'Чат запуска', 'chatId': 'chat', 'isDm': true, 'peerId': 'peer',
        'unread': 0, 'pinned': false, 'muted': false,
      }]), isTrue);
      final image = ChatFile(id: 'file', chatId: 'chat', messageId: 'message', fileName: 'saved.png',
        fileKey: 'saved.png', fileType: 'image/png', fileSize: 3, uploadedBy: uid, uploadedAt: now,
        fileUrl: 'https://studentsplatform.storage.yandexcloud.net/chats/test/saved.png');
      final key = ChatFileAccess.keyFor(image.fileUrl)!;
      final path = '${dir.path}/authorized_chat_files/$uid/${sha256.convert(utf8.encode('$uid:$key'))}';
      final file = File(path); await file.parent.create(recursive: true); await file.writeAsBytes(bytes);
      await File('$path.grant').writeAsString('chat-file-grant-v2:$sid');
      final ticket = (await cache.begin('chat'))!;
      expect(await cache.saveServerPage(ticket, [Message(id: 'message', chatId: 'chat',
        authorId: uid, authorLogin: uid, authorName: 'Студент', text: 'Сообщение запуска',
        at: now, attachments: [image])], hasMore: false), isTrue);
      await closeProjectChatServerDatabase(db);
    });
    priorScope.dispose(); await events.close();
    var requests = 0;
    final transport = MockClient((_) async { requests++; throw const SocketException('offline'); });
    await tester.runAsync(() => app.debugInitializeOrdinaryApp(client: transport,
      databasePath: dir.path, databaseFactory: databaseFactoryFfi));
    await tester.pumpWidget(const app.StudentPlatformApp()); await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.textContaining('Студент запуска').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.textContaining('Студент запуска'), findsOneWidget);
    expect(requests, greaterThan(0));
    await tester.tap(find.text('Профиль').last); await tester.pumpAndSettle();
    tester.widget<StudentProfileScreenPreview>(find.byType(StudentProfileScreenPreview)).onMessagesTap!();
    await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.text('Чат запуска').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Чат запуска'), findsOneWidget);
    await tester.tap(find.text('Чат запуска')); await tester.pumpAndSettle();
    for (var i = 0; i < 80 && find.text('Сообщение запуска').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Сообщение запуска'), findsOneWidget);
    bool imageReady() => tester.widgetList<Image>(find.byType(Image)).any((image) =>
      image.image is MemoryImage && listEquals((image.image as MemoryImage).bytes, bytes));
    for (var i = 0; i < 80 && !imageReady(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(imageReady(), isTrue);
    await tester.tap(find.byTooltip('Назад').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Назад').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Выйти из аккаунта'));
    await tester.tap(find.text('Выйти из аккаунта'));
    for (var i = 0; i < 120 && Supabase.instance.client.auth.currentSession != null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(Supabase.instance.client.auth.currentSession, isNull);
    for (var i = 0; i < 120 && find.text('Без регистрации').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Без регистрации'), findsOneWidget);
    app.appRouter.go('/login');
    for (var i = 0; i < 5; i++) { await tester.pump(const Duration(milliseconds: 100)); }
    expect(app.appRouter.routerDelegate.currentConfiguration.uri.path, '/login');
    expect(find.text('Сообщение запуска'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Supabase.instance.dispose());
    debugDefaultTargetPlatformOverride = null;
  });
}
