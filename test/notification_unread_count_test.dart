import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('unread count distinguishes confirmed zero from errors', () async {
    var response = '5';
    var status = 200;
    final client = SupabaseClient('https://example.invalid', 'test',
        httpClient: MockClient((request) async => http.Response(response, status,
            headers: {'content-type': 'application/json'}, request: request)));
    final api = AppNotificationsApi(client: client);
    try {
      expect(await api.unreadCount(), 5);
      response = '0';
      expect(await api.unreadCount(), 0);
      response = 'null';
      await expectLater(api.unreadCount(), throwsFormatException);
      response = '-1';
      await expectLater(api.unreadCount(), throwsFormatException);
      response = '{"message":"unavailable"}';
      status = 500;
      await expectLater(api.unreadCount(), throwsA(isA<Exception>()));
    } finally {
      await client.dispose();
    }
  });
}
