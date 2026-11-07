import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_media_availability.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/authorized_file_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); sqfliteFfiInit();
  testWidgets('image retries after delayed protection becomes ready', (tester) async {
    late Directory root;
    late Database db;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/image.png';
    await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('image-ready-test-');
    db = await databaseFactoryFfi.openDatabase('${root.path}/db');
    await db.execute('CREATE TABLE chat_app_guards (token TEXT PRIMARY KEY, project TEXT NOT NULL, sid TEXT NOT NULL)');
    await db.insert('chat_app_guards', {'token': 'guard', 'project': '*', 'sid': ''});
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    final bytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAE0lEQVR4nGMsjtnHAANMcBZeDgBOQwGVsE+TnwAAAABJRU5ErkJggg==');
    final transport = MockClient((request) async => http.Response(jsonEncode({
      'url': url, 'accessPolicyVersion': 1, 'cacheable': false, 'expiresIn': 60,
    }), 200, request: request, headers: {'content-type': 'application/json'}));
    await Supabase.initialize(url: 'https://example.test', publishableKey: 'test', httpClient: transport,
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    await signInWithFileSession(Supabase.instance.client, 'receipt-user', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
    ChatFileAccess.debugHttpClientFactory = () => MockClient((request) async => http.Response.bytes(bytes, 200, request: request));
    });
    await tester.pumpWidget(MaterialApp(home: AuthorizedFileImage(imageUrl: url,
      errorWidget: (_, __, ___) => const Text('NOT_READY'))));
    for (var i = 0; i < 100 && find.text('Не удалось открыть вложение').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('Не удалось открыть вложение'), findsOneWidget);
    final owner = Object(); var retries = 0;
    PinnedMediaAvailability.attach(owner, () => retries++);
    PinnedMediaAvailability.unavailable(owner);
    await tester.pump();
    await tester.tap(find.text('Повторить')); await tester.pump();
    expect(retries, 1);
    final protection = MediaCacheProtection(db: db, root: root, project: 'https://example.test',
        databaseToken: 'guard', currentOwner: () => ChatFileAccess.userId);
    await tester.runAsync(() => protection.initialize()); protection.accessRecovery = Future.value(true);
    ChatFileAccess.mediaProtection = protection;
    for (var i = 0; i < 100 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.text('Не удалось открыть вложение'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    PinnedMediaAvailability.detach(owner);
    ChatFileAccess.mediaProtection = null; ChatFileAccess.debugHttpClientFactory = null;
    await tester.runAsync(() async { await Supabase.instance.dispose(); await db.close();
      messenger.setMockMethodCallHandler(paths, null); messenger.setMockMethodCallHandler(links, null);
      await root.delete(recursive: true); });
  }, skip: !const bool.fromEnvironment('PINNED_MEDIA_RUNTIME'));
}
