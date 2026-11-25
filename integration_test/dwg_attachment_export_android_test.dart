import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../test/chat_file_durable_receipt_test.dart' show signInWithFileSession;

// The Android runner selects Downloads in DocumentsUI and verifies the
// destination bytes independently. It must start with this filename absent.
const _run = String.fromEnvironment('DWG_EXPORT_RUN', defaultValue: 'default');
const _name = 'student-platform-qa-dwg-export-$_run.dwg';
const _contents = 'AC1032 Student Platform synthetic DWG export QA 20261125\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('saves cached drawing bytes through the Android document picker',
      (tester) async {
    if (!Platform.isAndroid ||
        (await PackageInfo.fromPlatform()).packageName !=
            'com.mill453020.studentplatform.offlinefixture') {
      throw StateError('The isolated Android offline fixture is required.');
    }
    if (!RegExp(r'^[a-zA-Z0-9-]{1,30}$').hasMatch(_run)) {
      throw StateError('Invalid Android fixture run name.');
    }

    await Supabase.initialize(
      url: 'https://example.invalid',
      publishableKey: 'fixture-only',
      httpClient: MockClient(
          (request) async => http.Response('offline', 503, request: request)),
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
    );
    addTearDown(() => Supabase.instance.dispose());
    var blobDownloads = 0;
    ChatFileAccess.debugHttpClientFactory = () => MockClient((request) async {
          blobDownloads++;
          return http.Response('offline', 503, request: request);
        });
    addTearDown(() => ChatFileAccess.debugHttpClientFactory = null);

    const sid = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    const url = 'https://${ChatFileAccess.storageHost}/chats/test/$_name';
    final bytes = ascii.encode(_contents);
    final root = await getApplicationCacheDirectory();
    final owners = Directory('${root.path}/authorized_chat_files');
    await owners.create(recursive: true);
    final owner = await owners.createTemp('dwg-export-qa-');
    final uid = owner.uri.pathSegments.where((part) => part.isNotEmpty).last;
    await signInWithFileSession(Supabase.instance.client, uid, sid);
    final digest =
        sha256.convert(utf8.encode('$uid:${ChatFileAccess.keyFor(url)!}'));
    final file = File('${owner.path}/$digest');
    final receipt = File('${file.path}.grant');
    await file.writeAsBytes(bytes, flush: true);
    await receipt.writeAsString('chat-file-grant-v2:$sid', flush: true);
    addTearDown(() async {
      for (final entry in <FileSystemEntity>[receipt, file, owner]) {
        try {
          await entry.delete();
        } on PathNotFoundException {
          // The authorization check may already have removed a receipt.
          if (await entry.exists()) rethrow;
        }
      }
    });

    await tester.pumpWidget(MaterialApp(
      home: FullscreenFileViewer(
        fileUrl: url,
        fileName: _name,
        fileSize: bytes.length,
      ),
    ));
    final save = find.text('Сохранить файл');
    expect(save, findsOneWidget);
    debugPrint('DWG_EXPORT_OPENING_PICKER $_name');
    await tester.tap(save);

    final success = find.text('Файл сохранён');
    final failure = find.text('Не удалось сохранить файл. Попробуйте ещё раз.');
    final wait = Stopwatch()..start();
    while (success.evaluate().isEmpty &&
        failure.evaluate().isEmpty &&
        wait.elapsed < const Duration(minutes: 2)) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(failure, findsNothing);
    expect(success, findsOneWidget);
    expect(blobDownloads, 0);
    debugPrint('DWG_EXPORT_PICKER_RETURNED $_name ${sha256.convert(bytes)}');
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
