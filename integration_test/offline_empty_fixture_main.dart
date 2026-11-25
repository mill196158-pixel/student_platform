// Standalone isolated Android fixture. Never use with the production app ID.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/serial_auth_local_storage.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/info/offline_subject_catalog.dart';
import 'package:student_platform/src/ui/info/useful_subject.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _OfflineHttp extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(const SocketException('synthetic offline'));
}

class _NoSocket implements WebSocketChannel {
  final StreamController<dynamic> _events = StreamController<dynamic>.broadcast();
  @override Stream<dynamic> get stream => _events.stream;
  @override WebSocketSink get sink => _NoSink(_events);
  @override Future<void> get ready => Future<void>.error(const SocketException('synthetic offline'));
  @override String? get protocol => null;
  @override int? get closeCode => null;
  @override String? get closeReason => null;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoSink implements WebSocketSink {
  _NoSink(this.events);
  final StreamController<dynamic> events;
  @override void add(dynamic data) {}
  @override void addError(Object error, [StackTrace? stackTrace]) {}
  @override Future<void> addStream(Stream<dynamic> stream) => stream.drain<void>();
  @override Future<void> close([int? closeCode, String? closeReason]) => events.close();
  @override Future<void> get done => events.done;
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _session(String uid) {
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final token = '${part({'alg': 'HS256'})}.${part({
    'iss': 'https://example.invalid/auth/v1', 'sub': uid,
    'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'aud': 'authenticated', 'role': 'authenticated', 'iat': now - 60, 'exp': now + 3600,
  })}.sig';
  return jsonEncode({
    'access_token': token, 'refresh_token': 'fixture-only', 'token_type': 'bearer',
    'expires_in': 3600, 'expires_at': now + 3600,
    'user': {'id': uid, 'aud': 'authenticated', 'app_metadata': {},
      'user_metadata': {}, 'created_at': '2026-01-01T00:00:00Z'},
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if ((await PackageInfo.fromPlatform()).packageName !=
      'com.mill453020.studentplatform.offlinefixture') {
    throw StateError('This fixture requires its isolated Android package.');
  }
  const materials = bool.fromEnvironment('E2E_MATERIALS_CHAT');
  const localAuth = bool.fromEnvironment('E2E_MATERIALS_LOCAL_AUTH');
  final backend = Uri.parse(SupabaseConfig.url);
  final allowedBackend = localAuth
      ? materials && backend.scheme == 'https' && backend.host == '127.0.0.1' &&
          backend.hasPort && backend.port >= 1024 && backend.path.isEmpty &&
          backend.userInfo.isEmpty && !backend.hasQuery && !backend.hasFragment
      : SupabaseConfig.url == 'https://example.invalid';
  if (!allowedBackend || SupabaseConfig.anonKey != 'fixture-only') {
    throw StateError('This fixture requires the synthetic backend configuration.');
  }
  final prefs = await SharedPreferences.getInstance();
  final root = materials ? await getApplicationSupportDirectory() : await getTemporaryDirectory();
  final databaseRoot = materials
      ? await Directory('${root.path}/materials_chat_fixture_${localAuth ? 'tls_${backend.port}' : 'v1'}').create()
      : await root.createTemp('empty_snapshot_fixture_');
  final marker = File('${databaseRoot.path}/seeded');
  final seeded = materials && await marker.exists();
  var expectedStudent = 'fixture-materials-student';
  if (localAuth && !seeded) {
    final cfg = jsonDecode(await File('${root.path}/student_materials_qa_config.json').readAsString());
    if (cfg['port'] != backend.port) throw StateError('Wrong local fixture port');
    final authority = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(await File('${root.path}/student_materials_qa_ca.pem').readAsBytes());
    final transport = IOClient(HttpClient(context: authority));
    final sdk = SupabaseClient(SupabaseConfig.url, cfg['anonKey'], httpClient: transport);
    try {
      final auth = await sdk.auth.signInWithPassword(email: cfg['email'], password: cfg['password']);
      final session = auth.session!;
      expectedStudent = session.user.id;
      final storage = createSerialSdkAuthStorage(SupabaseConfig.url);
      await storage.initialize();
      await storage.persistSession(jsonEncode(session.toJson()));
      debugPrint('MATERIALS_LOCAL_PASSWORD_GRANT');
    } finally {
      await sdk.dispose();
      transport.close();
    }
  } else if (localAuth) {
    expectedStudent = await marker.readAsString();
  } else if (!seeded) {
    final uid = materials ? 'fixture-materials-student' :
        'fixture-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    await prefs.setString('sb-example-auth-token', _session(uid));
  }
  await app.debugInitializeOrdinaryApp(
    client: _OfflineHttp(),
    databasePath: databaseRoot.path,
    databaseFactory: databaseFactory,
    realtimeOptions: RealtimeClientOptions(transport: (_, __) => _NoSocket()),
  );
  if (materials) {
    final cache = ProjectChatServerCache.qaInstance!;
    await cache.scope.ready;
    if (cache.scope.capture()?.userId != expectedStudent) {
      throw StateError('Missing isolated materials student');
    }
    if (!seeded) {
      final catalog = OfflineSubjectCatalog(cache);
      final ticket = await catalog.begin(isCurrent: () => true);
      final subject = UsefulSubject.fromRpcMap({
        'subject_offering_id': 'fixture-offering', 'subject_title': 'Предмет для проверки',
        'group_id': 'fixture-group', 'semester_number': 1, 'control_form': 'Экзамен',
        'team_id': 'fixture-team', 'chat_id': 'fixture-chat', 'can_open_chat': true,
      });
      final plan = {'contextData': {'userId': expectedStudent,
        'groupId': 'fixture-group', 'groupName': 'Тестовая группа', 'currentSemesterNumber': 1,
        'hasActiveEnrollment': true}, 'subjects': [subject.toJson()], 'warning': null};
      final page = await cache.begin('fixture-chat');
      if (ticket == null || !await catalog.commit(ticket, plan) || page == null ||
          !await cache.saveServerPage(page, [
            Message(id: 'fixture-message', chatId: 'fixture-chat', authorId: 'fixture-peer',
                authorLogin: '', authorName: 'Тестовый участник',
                text: 'Проверка истории предмета', at: DateTime.now().toUtc()),
          ], hasMore: false)) {
        throw StateError('Synthetic materials fixture was not saved');
      }
      await marker.writeAsString(expectedStudent, flush: true);
    }
    debugPrint(seeded ? 'MATERIALS_FIXTURE_REOPENED' : 'MATERIALS_FIXTURE_SEEDED');
  } else {
    debugPrint('OFFLINE_EMPTY_FIXTURE_READY');
  }
  runApp(const app.StudentPlatformApp());
}
