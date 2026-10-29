import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/learning/learning_screen.dart';
import 'package:student_platform/src/ui/schedule/schedule_screen.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Explicit owner-provided account; no credentials committed. This checks login
// and screen rendering, not every action in every nested screen.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const approved = bool.fromEnvironment('E2E_MAIN_APPROVED');
  const url = String.fromEnvironment('SUPABASE_URL');
  const login = String.fromEnvironment('E2E_LOGIN');
  const password = String.fromEnvironment('E2E_PASSWORD');
  if (!approved ||
      url != 'https://gwdanmwluhrcfxbnplwd.supabase.co' ||
      login.isEmpty ||
      password.isEmpty) {
    throw StateError('Explicit owner-approved account defines required');
  }
  testWidgets('approved account login and primary navigation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await app.main();
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (finder.evaluate().isNotEmpty) return;
      }
      fail('Screen did not appear: $finder');
    }

    await waitFor(find.text('Войти'));
    await tester.enterText(find.byType(TextFormField).first, login);
    await tester.enterText(find.byType(TextFormField).last, password);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text('Войти'));
    await tester.tap(find.text('Войти'));
    await waitFor(find.byType(NavigationScreen));
    expect(Supabase.instance.client.auth.currentUser, isNotNull);
    // The destination exists during the route animation; wait before tapping.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // First-login push pre-permission sheet is a real user flow.
    if (find.text('Не пропускайте важное').evaluate().isNotEmpty) {
      await tester.tap(find.text('Не сейчас'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Не пропускайте важное'), findsNothing);
    }
    final previousHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
    addTearDown(() =>
        WidgetController.hitTestWarningShouldBeFatal = previousHitTestPolicy);
    WidgetController.hitTestWarningShouldBeFatal = true;
    final tabs = <String, Type>{
      'Главная': HomeScreen,
      'База': InfoScreen,
      'Обучение': LearningScreen,
      'Расписание': ScheduleScreen,
      'Профиль': ProfileScreen
    };
    for (final entry in tabs.entries) {
      final button = find.descendant(
          of: find.byType(StudentBottomNav), matching: find.text(entry.key));
      await tester.tap(button);
      await waitFor(find.byType(entry.value));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull,
          reason: 'Render error in ${entry.key}');
      debugPrint('E2E rendered primary tab: ${entry.key}');
    }
    // Deep-route rendering only; no edits to existing student data.
    for (final route in [
      '/edit-profile',
      '/exams',
      '/my-diary',
      '/my-reviews',
      '/notification-settings'
    ]) {
      app.appRouter.go(route);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (route == '/my-diary') {
        final sections = find.byType(ExpansionTile);
        expect(sections, findsWidgets);
        final count = sections.evaluate().length;
        for (var i = 0; i < count; i++) {
          final tile = sections.at(i);
          await tester.ensureVisible(tile);
          await tester.pump(const Duration(milliseconds: 300));
          final title = tester.widget<ExpansionTile>(tile).title;
          await tester.tap(find.byWidget(title));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tap(find.byWidget(title));
          await tester.pump(const Duration(milliseconds: 400));
        }
      }
      expect(app.appRouter.routeInformationProvider.value.uri.path, route);
      expect(tester.takeException(), isNull, reason: 'Render error in $route');
      debugPrint('E2E rendered route: $route');
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
