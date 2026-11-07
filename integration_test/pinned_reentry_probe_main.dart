import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/src/core/media_cache_protection.dart';
import 'package:student_platform/src/core/pinned_access_fence.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName != 'com.example.offline_grant_qa') throw StateError('isolated package required');
  try {
    const project = 'https://example.invalid', uid = 'qa-user', sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/pixel3.png';
    final bytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAE0lEQVR4nGMsjtnHAANMcBZeDgBOQwGVsE+TnwAAAABJRU5ErkJggg==');
    final transport = MockClient((request) async => http.Response(jsonEncode({'url': url, 'accessPolicyVersion': 1,
      'cacheable': false, 'expiresIn': 60}), 200, request: request, headers: {'content-type': 'application/json'}));
    await Supabase.initialize(url: project, publishableKey: 'synthetic', httpClient: transport,
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    String b(Object x) => base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    await Supabase.instance.client.auth.recoverSession(jsonEncode({
      'access_token': '${b({'alg': 'HS256'})}.${b({'sub': uid, 'exp': exp, 'session_id': sid})}.sig',
      'token_type': 'bearer', 'refresh_token': 'synthetic', 'expires_at': exp, 'expires_in': 3600,
      'user': {'id': uid, 'app_metadata': {}, 'user_metadata': {}, 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z'}}));
    final root = await getApplicationCacheDirectory();
    final db = await openProjectChatServerDatabase('${await getDatabasesPath()}/pinned_reentry_probe_v1.db');
    final registry = MediaCacheProtection(db: db, root: root, project: project,
      databaseToken: debugProjectChatDatabaseGuard(db)!, currentOwner: () => ChatFileAccess.userId);
    await registry.initialize(); registry.accessRecovery = Future.value(true);
    if (!await registry.beginOwnerReadWindow(uid, () => ChatFileAccess.userId == uid)) throw StateError('owner window unavailable');
    ChatFileAccess.mediaProtection = registry;
    final key = ChatFileAccess.keyFor(url)!;
    final source = File('${root.path}/authorized_chat_files/$uid/${registry.digest(uid, key)}');
    await source.parent.create(recursive: true); await source.writeAsBytes(bytes);
    var downloads = 0;
    ChatFileAccess.debugHttpClientFactory = () => MockClient((request) async { downloads++; return http.Response.bytes(bytes, 200, request: request); });
    await ChatFileAccess.resolve(url);
    final first = await ChatFileAccess.readBytes(url);
    if (first.length != bytes.length) throw StateError('legacy read failed');
    final fence = PinnedAccessFence(db);
    for (var i = 0; i < 200 && !await fence.canRead(project, uid, key); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (!await fence.canRead(project, uid, key)) throw StateError('verified pin not ready');
    final samples = <int>[];
    for (var i = 0; i < 10; i++) {
      final sw = Stopwatch()..start();
      final read = await ChatFileAccess.readCachedOnly(url, permit: () => true);
      samples.add(sw.elapsedMicroseconds);
      if (read == null || read.length != bytes.length) throw StateError('reentry failed');
    }
    if (downloads != 1) throw StateError('duplicate download: $downloads');
    await source.delete();
    final offline = await ChatFileAccess.readCachedOnly(url, permit: () => true);
    if (offline == null) throw StateError('offline pin missing');
    final completer = Completer<void>();
    final stream = MemoryImage(Uint8List.fromList(offline)).resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener((_, __) { if (!completer.isCompleted) completer.complete(); },
      onError: (Object e, StackTrace? s) { if (!completer.isCompleted) completer.completeError(e, s); });
    stream.addListener(listener); await completer.future.timeout(const Duration(seconds: 5)); stream.removeListener(listener);
    samples.sort();
    debugPrint('CODEX_PIN_REENTRY_PASS p50_us=${samples[5]} p95_us=${samples[9]} downloads=$downloads');
    runApp(MaterialApp(home: Scaffold(body: Center(child: Image.memory(offline, width: 160, height: 160)))));
  } catch (e, s) {
    debugPrint('CODEX_PIN_REENTRY_FAIL $e $s');
    runApp(const MaterialApp(home: Scaffold(body: Text('Isolated reentry probe: fail'))));
  }
}
