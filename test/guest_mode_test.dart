import 'dart:io';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/shared/student_section_headers.dart';
import 'dart:async';
import 'package:student_platform/src/ui/guest/guest_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_platform/src/core/password_policy.dart';

class DenyNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('Guest must not access network');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'guest layouts fit a narrow phone and search does not hide profile favorites',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    for (final tab in [0, 1, 2, 3, 4]) {
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: GuestWorkspace(tab: tab))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'tab $tab at 320px');
      final shared = [
        StudentHomeView,
        StudentInfoHeader,
        StudentLearningHeader,
        StudentScheduleHeader,
        StudentProfileScreenPreview
      ][tab];
      expect(find.byType(shared), findsOneWidget);
    }
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GuestWorkspace(tab: 1))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('В избранное').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('В избранное').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('В избранное').at(1));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Избранное'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Избранное'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Производная');
    await tester.pumpAndSettle();
    expect(find.text('Производная: правило произведения'), findsOneWidget);
    expect(find.text('Единицы давления'), findsNothing);
    await tester.tap(find.text('Все материалы'));
    await tester.enterText(find.byType(TextField), 'нет такого материала');
    await tester.pumpAndSettle();
    expect(find.text('Материалы не найдены. Попробуй другой запрос.'),
        findsOneWidget);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GuestWorkspace(tab: 4))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Производная: правило произведения'));
    await tester.pumpAndSettle();
    expect(find.text('Производная: правило произведения').hitTestable(),
        findsOneWidget);
    expect(find.text('Единицы давления'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('guest route never calls profile policy; private route stays protected',
      () async {
    var calls = 0;
    Future<bool> policy() async {
      calls++;
      return true;
    }

    expect(
        await authRouteRedirect(
            path: '/guest', hasSession: false, passwordChangeRequired: policy),
        isNull);
    expect(
        await authRouteRedirect(
            path: '/my-diary',
            hasSession: false,
            passwordChangeRequired: policy),
        '/login');
    expect(calls, 0);
    expect(
        await authRouteRedirect(
            path: '/home', hasSession: true, passwordChangeRequired: policy),
        '/change-password');
  });
  testWidgets('invalid local rows are ignored and failed save rolls back',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'guest_workspace_v1':
          '{"notes":[{"id":"x","title":1,"body":null,"date":"bad"}],"plans":[],"favorites":[]}'
    });
    final gate = Completer<bool>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: GuestWorkspace(tab: 1, saveSnapshot: (_) => gate.future))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('В избранное').first);
    await tester.pump();
    expect(
        tester
            .widgetList<AbsorbPointer>(find.byType(AbsorbPointer))
            .any((w) => w.absorbing),
        isTrue);
    gate.complete(false);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.star), findsNothing);
    expect(find.text('Не удалось сохранить на устройстве. Повторите действие.'),
        findsOneWidget);
    await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GuestWorkspace(tab: 4))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'all guest tabs operate without Supabase, persist local notes and favorites',
      (tester) async {
    SharedPreferences.setMockInitialValues({'user': 'private account cache'});
    final network = DenyNetwork();
    final old = HttpOverrides.current;
    HttpOverrides.global = network;
    addTearDown(() => HttpOverrides.global = old);
    final router = GoRouter(initialLocation: '/guest', routes: [
      GoRoute(
          path: '/guest',
          builder: (_, __) => const NavigationScreen(guest: true)),
      GoRoute(
          path: '/login',
          builder: (_, __) => const Scaffold(body: Text('Login target'))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('Привет! 👋'), findsOneWidget);
    await tester.tap(find.text('База').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('В избранное').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Обучение').last);
    await tester.pumpAndSettle();
    expect(find.text('Войти в команды'), findsOneWidget);
    await tester.tap(find.text('Профиль').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Добавить заметку'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text('Добавить заметку'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить заметку'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Гостевая заметка');
    await tester.enterText(find.byType(TextField).at(1), 'Мой разбор задачи');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Гостевая заметка'), findsOneWidget);
    await tester.tap(find.text('Расписание').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить в план'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Подготовка');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Подготовка'), findsOneWidget);
    await tester.tap(find.text('Профиль').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('Производная: правило произведения'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Производная: правило произведения'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('guest_workspace_v1'), contains('Гостевая заметка'));
    expect(prefs.getString('user'), 'private account cache');
    expect(network.calls, 0);
    // Destroy state, then read the actual persisted device workspace.
    router.go('/login');
    await tester.pumpAndSettle();
    router.go('/guest');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Профиль').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Гостевая заметка'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Гостевая заметка'), findsOneWidget);
    await tester.ensureVisible(find.text('Войти').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Войти').first);
    await tester.pumpAndSettle();
    expect(find.text('Больше возможностей'), findsOneWidget);
    await tester.ensureVisible(find.text('Войти').last);
    await tester.tap(find.text('Войти').last);
    await tester.pumpAndSettle();
    expect(find.text('Login target'), findsOneWidget);
    expect(network.calls, 0);
  });
}
