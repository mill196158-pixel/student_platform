import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/app/admin_app.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';
import 'package:student_platform_admin/features/content/news/news_editor_screen.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  tearDown(() {
    AdminBackendConfig.debugDemoModeOverride = null;
  });

  testWidgets('admin dashboard opens in demo mode', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    await tester.pumpWidget(const AdminApp());
    await tester.pumpAndSettle();

    expect(find.text('Рабочее пространство'), findsOneWidget);
    expect(find.text('Локальный прототип'), findsWidgets);
  });

  testWidgets('news editor embeds shared student home view', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NewsEditorScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StudentHomeView), findsOneWidget);
    expect(find.text('Привет, Минь 👋'), findsOneWidget);
    expect(find.text('Сводка дня'), findsOneWidget);
  });
}
