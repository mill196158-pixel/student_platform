// Standalone isolated Android fixture. Never use with the production app ID.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';
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
  if (SupabaseConfig.url != 'https://example.invalid' ||
      SupabaseConfig.anonKey != 'fixture-only') {
    throw StateError('This fixture requires the synthetic backend configuration.');
  }
  final random = Random.secure();
  final uid = 'fixture-${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}';
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('sb-example-auth-token', _session(uid));
  final root = await getTemporaryDirectory();
  final databaseRoot = await root.createTemp('empty_snapshot_fixture_');
  await app.debugInitializeOrdinaryApp(
    client: _OfflineHttp(),
    databasePath: databaseRoot.path,
    databaseFactory: databaseFactory,
    realtimeOptions: RealtimeClientOptions(transport: (_, __) => _NoSocket()),
  );
  debugPrint('OFFLINE_EMPTY_FIXTURE_READY');
  runApp(const app.StudentPlatformApp());
}
