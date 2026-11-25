import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:student_platform/src/navigation/root_nav.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Second client for the synchronized Android/Windows notification-center run.
/// The private fixture contains local test login parameters and both row titles.
/// The coordinating device supplies the tap time once both centers are visible.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['STUDENT_NOTIFICATION_PAIR_FIXTURE'];
  if (path == null) {
    test('requires a paired local Android test device', () {}, skip: true);
    return;
  }
  final config = File(path);
  final fixture = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  File signal(String name) => File('${config.parent.path}/$name');
  setUpAll(() async {
    await initializeDateFormatting('ru_RU');
    await Supabase.initialize(
      url: 'http://127.0.0.1:55321',
      publishableKey: fixture['anonKey'] as String,
      authOptions: FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: EmptyLocalStorage()),
    );
    final login = await Supabase.instance.client.auth.signInWithPassword(
      email: fixture['email'] as String,
      password: fixture['password'] as String,
    );
    expect(login.user?.id, fixture['recipientId']);
  });
  tearDownAll(() async {
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
    await Supabase.instance.dispose();
  });
  testWidgets('both native clients mark the same inbox item', (tester) async {
    Future<void> waitFor(Finder target) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (target.evaluate().isEmpty && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 70));
      }
      expect(target, findsWidgets);
    }

    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootNavigatorKey,
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => showNotificationCenterSheet(context),
          child: const Text('Open history'),
        );
      })),
    ));
    final target = find.text(fixture['targetTitle'] as String);
    final neighbor = find.text(fixture['neighborTitle'] as String);
    await tester.tap(find.text('Open history'));
    await waitFor(target);
    await tester.ensureVisible(target.first);
    await tester.pumpAndSettle();
    await signal('windows-ready').writeAsString('ready', flush: true);
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (!await signal('tap-at').exists() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    final when = int.parse(await signal('tap-at').readAsString());
    final remaining = when - DateTime.now().millisecondsSinceEpoch;
    if (remaining > 0)
      await Future<void>.delayed(Duration(milliseconds: remaining));
    final tappedAt = DateTime.now().millisecondsSinceEpoch;
    await tester.tap(target.first);
    await signal('windows-tapped').writeAsString('$tappedAt', flush: true);
    await tester.pumpAndSettle();
    // Reopen the sheet to read the server's final state for both clients.
    rootNavigatorKey.currentState!.popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open history'));
    await waitFor(target);
    if (neighbor.evaluate().isEmpty) {
      final more = find.textContaining('Ещё ');
      await tester.ensureVisible(more.last);
      await tester.tap(more.last);
      await tester.pumpAndSettle();
    }
    await waitFor(neighbor);
    expect(find.bySemanticsLabel(RegExp(r'Непрочитанных: 1')), findsWidgets);
    final rows = await Supabase.instance.client
        .from('app_notifications')
        .select('id,read_at')
        .inFilter('id', [fixture['targetId'], fixture['neighborId']]);
    expect(rows.singleWhere((r) => r['id'] == fixture['targetId'])['read_at'],
        isNotNull);
    expect(rows.singleWhere((r) => r['id'] == fixture['neighborId'])['read_at'],
        isNull);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
