import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/core/navigation/admin_shell.dart';

void main() {
  testWidgets('sidebar ListTiles have a local transparent Material', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = AdminSessionController()
      ..phase = AdminSessionPhase.localPrototype;
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AdminShell(
          currentPath: '/dashboard',
          session: session,
          child: const SizedBox(),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Material && widget.type == MaterialType.transparency,
      ),
      findsOneWidget,
    );
    expect(find.byType(ListTile), findsWidgets);
  });
}
