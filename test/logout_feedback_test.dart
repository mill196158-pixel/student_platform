import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/logout_cleanup.dart';
import 'package:student_platform/src/core/logout_feedback.dart';

void main() {
  for (final test in [
    (
      LogoutCleanupResult.blockedBeforeSignOut,
      'Не удалось завершить выход. Попробуйте ещё раз.'
    ),
    (
      LogoutCleanupResult.signOutUnconfirmed,
      'Не удалось подтвердить выход. Проверьте соединение.'
    ),
    (
      LogoutCleanupResult.signedOutCleanupIncomplete,
      'Вы вышли из аккаунта, но часть локальных данных не удалось очистить.'
    ),
  ]) {
    testWidgets('logout feedback survives source page removal: ${test.$1}',
        (tester) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        scaffoldMessengerKey: messenger,
        home: const Scaffold(body: Text('source')),
      ));
      navigator.currentState!.pushReplacement(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('guest'))));
      await tester.pumpAndSettle();
      expect(find.text('source'), findsNothing);
      showLogoutFeedback(messenger, test.$1);
      await tester.pumpAndSettle();
      expect(find.text('guest'), findsOneWidget);
      expect(find.text(test.$2), findsOneWidget);
    });
  }
}
