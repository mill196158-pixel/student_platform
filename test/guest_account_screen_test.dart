import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:student_platform/src/ui/guest/guest_account_screen.dart';

void main() {
  testWidgets('guest explanation returns to source and separates auth modes',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(initialLocation: '/guest', routes: [
      GoRoute(
          path: '/guest',
          builder: (context, _) => Scaffold(
                body: TextButton(
                    onPressed: () => GuestAccountScreen.open(context),
                    child: const Text('Open')),
              )),
      GoRoute(
          path: '/login',
          builder: (_, state) => Scaffold(
                  body: Text(
                state.uri.queryParameters['mode'] == 'register'
                    ? 'Register target'
                    : 'Login target',
              ))),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(theme: ThemeData.dark(), routerConfig: router));
    for (final action in [
      'Продолжить без входа',
      'Зарегистрироваться',
      'Войти'
    ]) {
      router.go('/guest');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Больше возможностей'), findsOneWidget);
      await tester.ensureVisible(find.text(action));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(
          find.text(action == 'Продолжить без входа'
              ? 'Open'
              : action == 'Войти'
                  ? 'Login target'
                  : 'Register target'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}

