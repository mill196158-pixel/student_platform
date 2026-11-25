import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/services/push/app_notifications_api.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _origin = 'http://127.0.0.1:55321';

class _TestSockets extends HttpOverrides {}

class _LocalHttp extends http.BaseClient {
  final local = IOClient(
      _TestSockets().createHttpClient(null)..findProxy = (_) => 'DIRECT');
  final secondWrite = Completer<void>();
  final release = Completer<void>();
  int writes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != _origin)
      throw StateError('Expected a loopback QA request');
    if (request.url.path.endsWith('/mark_all_notifications_read')) {
      if (++writes == 1)
        throw const SocketException('Simulated connection loss');
      if (writes == 2) {
        secondWrite.complete();
        await release.future;
      }
    }
    return local.send(request);
  }

  @override
  void close() => local.close();
}

void main() {
  final primaryPath = Platform.environment['STUDENT_CENTER_QA_PRIMARY'];
  final peerPath = Platform.environment['STUDENT_CENTER_QA_OTHER'];
  if (primaryPath != null && peerPath != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets(
      'read all includes older notifications, retries and survives closing the center',
      (tester) async {
    final primary = jsonDecode(File(primaryPath!).readAsStringSync()) as Map;
    final peer = jsonDecode(File(peerPath!).readAsStringSync()) as Map;
    final http = _LocalHttp(), peerHttp = _LocalHttp();
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: _origin,
        publishableKey: primary['anonKey'],
        httpClient: http,
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false));
    final client = Supabase.instance.client;
    final other =
        SupabaseClient(_origin, peer['anonKey'], httpClient: peerHttp);
    try {
      for (final (sdk, config) in [(client, primary), (other, peer)]) {
        await sdk.auth.signInWithPassword(
            email: config['email'], password: config['password']);
        expect(sdk.auth.currentUser?.id, config['recipientId']);
      }
      final api = AppNotificationsApi(client: client),
          otherApi = AppNotificationsApi(client: other);
      final rows = await api.listMine();
      expect(rows.length, 50);
      expect(rows.any((row) => row.isUnread), isFalse);
      expect(await api.unreadCount(), 1);
      expect(await otherApi.unreadCount(), 1);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
                  builder: (ctx) => TextButton(
                      onPressed: () => showNotificationCenterSheet(ctx),
                      child: const Text('Inbox'))))));
      await tester.tap(find.text('Inbox'));
      Future<void> until(bool Function() condition) async {
        for (var i = 0; i < 80 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 30));
        }
        expect(condition(), isTrue);
      }

      final all = find.widgetWithText(TextButton, 'Прочитать все');
      await until(() =>
          all.evaluate().isNotEmpty && tester.widget<TextButton>(all).enabled);
      await tester.tap(all);
      await until(() => find
          .text('Не удалось отметить уведомления прочитанными')
          .evaluate()
          .isNotEmpty);
      expect(await api.unreadCount(), 1);
      await tester.tap(all);
      await until(() => http.secondWrite.isCompleted);
      await until(() => !tester.widget<TextButton>(all).enabled);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(all, findsNothing);
      http.release.complete();
      for (var i = 0; i < 60 && await api.unreadCount() != 0; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(await api.unreadCount(), 0);
      expect(await otherApi.unreadCount(), 1);
      expect(http.writes, 2);
      expect(tester.takeException(), isNull);
    } finally {
      if (!http.release.isCompleted) http.release.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await other.dispose();
      await Supabase.instance.dispose();
    }
  }, skip: primaryPath == null || peerPath == null);
}
