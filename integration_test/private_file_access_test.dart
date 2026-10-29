import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/services/chat_file_access.dart';

class AccessTransport extends http.BaseClient {
  final inner = http.Client();
  String mode = '';
  @override
  Future<http.StreamedResponse> send(http.BaseRequest req) async {
    if (req.url.path.endsWith('/chat-file-access')) {
      if (mode == 'offline') throw const SocketException('test offline');
      if (mode == 'denied')
        return http.StreamedResponse(
            Stream.value('{"error":"file_unavailable"}'.codeUnits), 403,
            headers: {'content-type': 'application/json'});
    }
    return inner.send(req);
  }

  @override
  void close() {
    inner.close();
    super.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const login = String.fromEnvironment('E2E_LOGIN');
  const file = String.fromEnvironment('E2E_FILE_URL');
  if (!const bool.fromEnvironment('E2E_LIVE_APPROVED') ||
      !login.startsWith('e2e_') ||
      url != 'https://gwdanmwluhrcfxbnplwd.supabase.co' ||
      !file.contains('/chats/')) throw StateError('Synthetic fixture required');
  testWidgets('private file real bytes, offline cache, revocation and logout',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final transport = AccessTransport();
    await Supabase.initialize(
        url: url,
        anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
        httpClient: transport);
    final sb = Supabase.instance.client;
    addTearDown(() async {
      transport.mode = '';
      await ChatFileAccess.clear();
      await Supabase.instance.dispose();
      transport.close();
    });
    await sb.auth.signInWithPassword(
        email: '$login@student.local',
        password: const String.fromEnvironment('E2E_PASSWORD'));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Text('Private attachment regression'))));
    await ChatFileAccess.clear();
    final online = await ChatFileAccess.readBytes(file);
    expect(online, isNotEmpty);
    transport.mode = 'offline';
    expect(await ChatFileAccess.readBytes(file), online);
    await ChatFileAccess.authorize(file);
    transport.mode = 'denied';
    await expectLater(
        ChatFileAccess.readBytes(file), throwsA(isA<FunctionException>()));
    transport.mode = 'offline';
    await expectLater(
        ChatFileAccess.readBytes(file), throwsA(isA<SocketException>()));
    transport.mode = '';
    expect(await ChatFileAccess.readBytes(file), online);
    final temporary = await ChatFileAccess.forwardTemp(file);
    expect(await temporary.exists(), isTrue);
    await ChatFileAccess.releaseForwardTemp(temporary.path);
    expect(await temporary.exists(), isFalse);
    final logoutTemporary = await ChatFileAccess.forwardTemp(file);
    await ChatFileAccess.clear();
    expect(await logoutTemporary.exists(), isFalse);
    transport.mode = 'offline';
    await expectLater(
        ChatFileAccess.readBytes(file), throwsA(isA<SocketException>()));
    transport.mode = '';
    await sb.auth.signOut();
    await expectLater(
        ChatFileAccess.readBytes(file), throwsA(isA<StateError>()));
    expect(tester.takeException(), isNull);
  });
}
