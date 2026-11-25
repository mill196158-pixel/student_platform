import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/learning/data/supabase_learning_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Sockets extends HttpOverrides {}

class _Observed extends http.BaseClient {
  final inner =
      IOClient(_Sockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final requests = <String>[];
  bool interrupt = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != 'http://127.0.0.1:55321')
      throw StateError('Only loopback allowed');
    requests.add(request.url.path);
    if (interrupt &&
        (request.url.queryParameters['created_at'] != null ||
            (request is http.Request &&
                request.url.path.endsWith('/get_chat_messages_page') &&
                request.body.contains('p_before_at')))) {
      throw const SocketException('Deliberate page interruption');
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cfgFile = Platform.environment['STUDENT_MATERIALS_LOCAL_CONFIG'];
  test('interrupted older history can resume at an equal-time UUID cursor',
      () async {
    final ids = jsonDecode(
        File(Platform.environment['STUDENT_MATERIALS_LOCAL_MANIFEST']!)
            .readAsStringSync()) as Map;
    final cfg = jsonDecode(File(cfgFile!).readAsStringSync()) as Map;
    final transport = _Observed();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/events'),
            (_) async => null);
    await Supabase.initialize(
        url: 'http://127.0.0.1:55321',
        publishableKey: cfg['anonKey'] as String,
        httpClient: transport,
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false));
    final client = Supabase.instance.client;
    try {
      await client.auth.signInWithPassword(
          email: cfg['email'] as String, password: cfg['password'] as String);
      final team = ids['team'] as String;
      final repo = SupabaseLearningRepository();
      final first = await repo.loadChat(team);
      expect(first, hasLength(100));
      final sorted = [...first]..sort((a, b) {
          final order = a.at.compareTo(b.at);
          return order == 0 ? a.id.compareTo(b.id) : order;
        });
      final cursor = sorted.first;
      transport.interrupt = true;
      await expectLater(
          repo.loadOlderMessages(team, cursor), throwsA(isA<Exception>()));
      transport.interrupt = false;
      transport.requests.clear();
      final clock = Stopwatch()..start();
      final older = await repo.loadOlderMessages(team, cursor);
      final count = transport.requests.length;
      print(
          'Older page: ${older.length} messages, $count HTTP calls, ${clock.elapsedMilliseconds} ms');
      final unique = {...first.map((m) => m.id), ...older.map((m) => m.id)};
      expect(unique, hasLength(123));
      expect(first.length + older.length, 123);
      final original = older.singleWhere((m) => m.id == ids['older']);
      expect(original.authorName, isNotEmpty);
      expect(original.attachments!.single.fileName, 'Plan.dwg');
      expect(count, lessThanOrEqualTo(2));
      print(
          'PASS 028 transport interruption then retry, 123 unique messages and original attachment, true local account');
    } finally {
      await Supabase.instance.dispose();
      transport.close();
    }
  }, skip: cfgFile == null);
}
