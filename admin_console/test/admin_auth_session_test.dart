import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/app/admin_app.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';
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
    AdminBackendConfig.debugDemoModeOverride = null;
  });

  testWidgets('demo mode opens local prototype', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = true;
    await tester.pumpWidget(const AdminApp());
    await tester.pumpAndSettle();

    expect(find.text('Локальный прототип'), findsWidgets);
    expect(find.text('Рабочее пространство'), findsOneWidget);
  });

  testWidgets('real mode shows login fields when signed out', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = false;
    final session = _TestSession(initialPhase: AdminSessionPhase.signedOut);
    await tester.pumpWidget(MaterialApp(home: LoginScreen(session: session)));
    await tester.pumpAndSettle();

    expect(find.text('Войти'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Пароль'), findsOneWidget);
    expect(find.text('Подключено'), findsOneWidget);
    expect(find.text('Забыли пароль?'), findsOneWidget);
  });

  test('password reset redirectTo is site root on port 3000', () {
    expect(
      AdminBackendConfig.passwordResetRedirectTo,
      'http://localhost:3000/',
    );
    expect(AdminBackendConfig.passwordResetRedirectTo, isNot(contains('#')));
    expect(AdminBackendConfig.passwordResetRedirectTo, isNot(contains('?')));
    expect(
      AdminBackendConfig.passwordResetRedirectTo,
      isNot(contains('reset-password')),
    );
  });

  testWidgets('passwordRecovery opens reset screen', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = false;
    final session = AdminSessionController(
      initializeSupabase: () async {},
      loadCapabilities: () async => AdminCapabilities.empty,
      signOut: () async {},
    );
    session.debugEnterPasswordRecovery();

    await tester.pumpWidget(AdminApp(session: session));
    await tester.pumpAndSettle();

    expect(find.text('Новый пароль'), findsWidgets);
    expect(find.text('Повторите пароль'), findsOneWidget);
    expect(find.text('Сохранить пароль'), findsOneWidget);
    expect(find.text('Войти'), findsNothing);
  });

  test('bootstrap does not overwrite passwordRecovery latch', () async {
    AdminBackendConfig.debugDemoModeOverride = false;
    var capabilitiesLoaded = false;
    final session = AdminSessionController(
      initializeSupabase: () async {},
      loadCapabilities: () async {
        capabilitiesLoaded = true;
        return const AdminCapabilities(
          userId: 'admin-1',
          permissions: {'dashboard.view'},
          assignments: [],
        );
      },
      signOut: () async {},
    );

    session.debugEnterPasswordRecovery();
    await session.startAuthEarly();
    await session.completeBootstrap();

    expect(session.phase, AdminSessionPhase.passwordRecovery);
    expect(session.isPasswordRecovery, isTrue);
    expect(capabilitiesLoaded, isFalse);
  });

  testWidgets('successful password change signs out and opens login', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = false;
    var signedOut = false;
    var updatedPassword = '';
    final session = AdminSessionController(
      initializeSupabase: () async {},
      loadCapabilities: () async => AdminCapabilities.empty,
      signOut: () async {
        signedOut = true;
      },
      updatePassword: (password) async {
        updatedPassword = password;
      },
    );
    session.debugEnterPasswordRecovery();

    await tester.pumpWidget(AdminApp(session: session));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Новый пароль'),
      'new-pass-123',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Повторите пароль'),
      'new-pass-123',
    );
    await tester.tap(find.text('Сохранить пароль'));
    await tester.pumpAndSettle();

    expect(updatedPassword, 'new-pass-123');
    expect(signedOut, isTrue);
    expect(session.phase, AdminSessionPhase.signedOut);
    expect(session.infoMessage, 'Пароль изменён');
    expect(find.text('Войти'), findsOneWidget);
    expect(find.text('Пароль изменён'), findsOneWidget);
  });

  testWidgets('requestPasswordReset shows info without tokens', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = false;
    var capturedEmail = '';
    final session = AdminSessionController(
      initializeSupabase: () async {},
      loadCapabilities: () async => AdminCapabilities.empty,
      signOut: () async {},
      resetPasswordForEmail: (email) async {
        capturedEmail = email;
      },
    );
    session.phase = AdminSessionPhase.signedOut;

    await session.requestPasswordReset(email: 'admin@example.com');
    expect(capturedEmail, 'admin@example.com');
    expect(session.infoMessage, isNotNull);
    expect(session.infoMessage!.toLowerCase(), isNot(contains('access_token')));
    expect(
      session.infoMessage!.toLowerCase(),
      isNot(contains('refresh_token')),
    );
  });

  testWidgets('updatePassword signs out and sets success message', (
    tester,
  ) async {
    AdminBackendConfig.debugDemoModeOverride = false;
    var updated = false;
    final session = AdminSessionController(
      initializeSupabase: () async {},
      loadCapabilities: () async => AdminCapabilities.empty,
      signOut: () async {},
      updatePassword: (password) async {
        updated = password == 'new-pass-123';
      },
    );
    session.debugEnterPasswordRecovery();

    await session.updatePassword(password: 'new-pass-123');
    expect(updated, isTrue);
    expect(session.phase, AdminSessionPhase.signedOut);
    expect(session.infoMessage, 'Пароль изменён');
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

  testWidgets('logout clears admin session in real mode', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = false;
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

  testWidgets('config error does not fall back to demo', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = false;
    final session = AdminSessionController(
      initializeSupabase: () async {
        throw StateError('backend unavailable');
      },
    );
    await session.bootstrap();
    expect(session.phase, AdminSessionPhase.error);
    expect(session.isLocalPrototype, isFalse);
    expect(session.errorMessage, isNotNull);
  });

  testWidgets('news editor still works locally', (tester) async {
    AdminBackendConfig.debugDemoModeOverride = true;
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
