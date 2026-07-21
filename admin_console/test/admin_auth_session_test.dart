import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/app/admin_app.dart';
import 'package:student_platform_admin/core/auth/admin_auth_config.dart';
import 'package:student_platform_admin/core/auth/admin_capabilities.dart';
import 'package:student_platform_admin/core/auth/admin_session_controller.dart';
import 'package:student_platform_admin/core/auth/login_screen.dart';
import 'package:student_platform_admin/core/auth/no_access_screen.dart';
import 'package:student_platform_admin/features/content/news/news_editor_screen.dart';
import 'package:student_ui/student_ui.dart';

class _TestSession extends AdminSessionController {
  _TestSession({
    required AdminSessionPhase initialPhase,
    AdminCapabilities capabilities = AdminCapabilities.empty,
  }) : super(
         initializeSupabase: () async {},
         loadCapabilities: () async => capabilities,
         signIn: (email, password) async {
           throw UnimplementedError();
         },
         signOut: () async {},
       ) {
    phase = initialPhase;
    this.capabilities = capabilities;
  }
}

void main() {
  tearDown(() {
    AdminAuthConfig.debugIsConfiguredOverride = null;
  });

  testWidgets('without backend config opens local prototype', (tester) async {
    AdminAuthConfig.debugIsConfiguredOverride = false;
    await tester.pumpWidget(const AdminApp());
    await tester.pumpAndSettle();

    expect(find.text('Локальный прототип'), findsWidgets);
    expect(find.text('Рабочее пространство'), findsOneWidget);
  });

  testWidgets('configured mode shows login fields when signed out', (
    tester,
  ) async {
    AdminAuthConfig.debugIsConfiguredOverride = true;
    final session = _TestSession(initialPhase: AdminSessionPhase.signedOut);
    await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Войти'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Пароль'), findsOneWidget);
  });

  testWidgets('no capabilities shows no access', (tester) async {
    final session = _TestSession(initialPhase: AdminSessionPhase.noAccess);
    await tester.pumpWidget(
      MaterialApp(home: NoAccessScreen(session: session)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Нет доступа'), findsOneWidget);
    expect(find.text('Выйти'), findsOneWidget);
  });

  test('menu permission helpers match content and academic scopes', () {
    const contentOnly = AdminCapabilities(
      userId: 'admin-1',
      permissions: {'dashboard.view', 'content.read', 'content.write'},
      assignments: [],
    );
    expect(contentOnly.canReadContent, isTrue);
    expect(contentOnly.canReadAcademic, isFalse);

    const academicOnly = AdminCapabilities(
      userId: 'admin-2',
      permissions: {'dashboard.view', 'academic.read', 'subjects.write'},
      assignments: [],
    );
    expect(academicOnly.canReadAcademic, isTrue);
    expect(academicOnly.canReadContent, isFalse);
  });

  testWidgets('logout clears admin session', (tester) async {
    AdminAuthConfig.debugIsConfiguredOverride = true;
    final session = _TestSession(
      initialPhase: AdminSessionPhase.ready,
      capabilities: const AdminCapabilities(
        userId: 'admin-1',
        permissions: {'dashboard.view'},
        assignments: [],
      ),
    );

    await session.signOut();
    expect(session.capabilities.permissions, isEmpty);
    expect(session.phase, AdminSessionPhase.signedOut);
  });

  testWidgets('news editor still works locally', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: NewsEditorScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StudentHomeView), findsOneWidget);
    expect(find.text('Визуальный редактор новостей'), findsOneWidget);
  });
}
