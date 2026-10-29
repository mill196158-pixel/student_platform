import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart';

// This smoke deliberately does not submit credentials or mutate server data.
// Test preferences hide any existing device session without clearing it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('anonymous startup, validation, access screen and route guards',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await app.main();

    Future<void> waitFor(Finder target) async {
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (target.evaluate().isNotEmpty) return;
      }
      fail('Expected screen did not appear within 10 seconds: $target');
    }

    // Do not pumpAndSettle: the login cat is a repeating animation.
    await waitFor(find.text('Войти'));
    expect(Supabase.instance.client.auth.currentSession, isNull);
    await tester.ensureVisible(find.text('Войти'));
    await tester.tap(find.text('Войти'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Введите логин'), findsOneWidget);
    expect(find.text('Минимум 4 символа'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, 'e2e.invalid');
    await tester.enterText(find.byType(TextFormField).last, '123');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text('Войти'));
    await tester.tap(find.text('Войти'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Введите логин'), findsNothing);
    expect(find.text('Минимум 4 символа'), findsOneWidget);
    expect(Supabase.instance.client.auth.currentSession, isNull);

    final registration = find.text('Нет аккаунта? Зарегистрироваться');
    await tester.ensureVisible(registration);
    await tester.tap(registration);
    await waitFor(find.text('Вернуться ко входу'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text('Вернуться ко входу'));
    await waitFor(find.text('Войти'));

    // Direct navigation probes guards; this is NOT a test of private screens.
    for (final route in [
      '/home',
      '/profile',
      '/edit-profile',
      '/exams',
      '/my-diary',
      '/my-reviews',
      '/notification-settings',
      '/change-password',
    ]) {
      app.appRouter.go(route);
      await tester.pump(const Duration(milliseconds: 300));
      expect(app.appRouter.routeInformationProvider.value.uri.path, '/login',
          reason: 'Anonymous access must be denied for $route');
      expect(find.text('Войти'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
