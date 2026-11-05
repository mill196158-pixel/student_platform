import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/serial_auth_local_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'cold_start_session_test.dart' show sessionFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('SDK restores existing default-key session through wrapper', () async {
    final expiry =
        DateTime.now().add(const Duration(hours: 2)).millisecondsSinceEpoch ~/
            1000;
    final original = jsonEncode(sessionFixture(expiry));
    SharedPreferences.setMockInitialValues(
        {'sb-project-auth-token': original, 'other': 'safe'});
    final storage = createSerialSdkAuthStorage('https://project.supabase.co');
    await Supabase.initialize(
        url: 'https://project.supabase.co',
        publishableKey: 'test',
        authOptions: FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: storage),
        httpClient: MockClient(
            (request) async => http.Response('{}', 500, request: request)));
    expect(Supabase.instance.client.auth.currentUser?.id, 'test-user');
    await storage.drain();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sb-project-auth-token'), isNotNull);
    expect(prefs.getString('other'), 'safe');
    await Supabase.instance.dispose();
  });
}
