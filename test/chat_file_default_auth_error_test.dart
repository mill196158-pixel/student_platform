import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/chat_file_access.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('default listener preserves uncaught stream errors and fences signout', () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'https://example.invalid', publishableKey: 'test',
      httpClient: MockClient((_) async => http.Response('', 204)),
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false));
    const user = 'default-owner';
    const sid = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await signInWithFileSession(Supabase.instance.client, user, sid);
    const url = 'https://studentsplatform.storage.yandexcloud.net/chats/test/file.png';
    final errors = <Object>[];
    late String? session;
    runZonedGuarded(() {
      session = ChatFileAccess.currentSessionBinding;
    }, (error, _) => errors.add(error));
    final generation = ChatFileAccess.generation;
    expect(ChatFileAccess.isViewerCurrent(url, user: user, epoch: generation,
        sessionBinding: session), isTrue);
    Supabase.instance.client.auth.notifyException(
        AuthRetryableFetchException(message: 'network unavailable'));
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
    expect(ChatFileAccess.isViewerCurrent(url, user: user, epoch: generation,
        sessionBinding: session), isTrue);
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    await Future<void>.delayed(Duration.zero);
    expect(ChatFileAccess.isViewerCurrent(url, user: user, epoch: generation,
        sessionBinding: session), isFalse);
    await Supabase.instance.dispose();
  });
}
