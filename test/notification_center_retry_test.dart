import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('valid notification retains nullable fields and empty body', () async {
    final client = SupabaseClient('https://example.invalid', 'test', httpClient:
      MockClient((request) async => http.Response(jsonEncode([{
        'id': '123', 'event_type': 'dm_message', 'title': 'Новость', 'body': '',
        'created_at': '2026-11-06T12:00:00Z', 'data': <String, Object>{},
        'read_at': null, 'source_id': null,
      }]), 200, headers: {'content-type': 'application/json'}, request: request)));
    try {
      final items = await AppNotificationsApi(client: client).listMine();
      expect(items.single.title, 'Новость');
      expect(items.single.body, '');
      expect(items.single.readAt, isNull);
    } finally { await client.dispose(); }
  });
  testWidgets('failed notification load offers retry; confirmed empty is distinct', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('com.llfbandit.app_links/events');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    var calls = 0;
    await tester.runAsync(() => Supabase.initialize(
      url: 'https://example.invalid', publishableKey: 'test',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false, detectSessionInUri: false),
      httpClient: MockClient((request) async {
        expect(request.url.path, endsWith('/rpc/get_my_app_notifications'));
        calls++;
        return http.Response(calls == 1 ? jsonEncode({'message': 'offline'}) :
            calls == 2 ? jsonEncode({'unexpected': true}) :
            calls == 3 ? '[{}]' : '[]',
            calls == 1 ? 500 : 200,
            headers: {'content-type': 'application/json'}, request: request);
      }),
    ));
    try {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
          TextButton(onPressed: () => showNotificationCenterSheet(context), child: const Text('Открыть'))))));
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось загрузить уведомления'), findsOneWidget);
      expect(find.text('Пока нет уведомлений'), findsNothing);
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось загрузить уведомления'), findsOneWidget);
      expect(find.text('Пока нет уведомлений'), findsNothing);
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось загрузить уведомления'), findsOneWidget);
      expect(find.text('Пока нет уведомлений'), findsNothing);
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.text('Пока нет уведомлений'), findsOneWidget);
      expect(find.text('Не удалось загрузить уведомления'), findsNothing);
      expect(calls, 4);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await tester.runAsync(() => Supabase.instance.dispose());
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
