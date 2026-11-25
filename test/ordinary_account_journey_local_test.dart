import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_transition_host.dart';
import 'package:student_platform/src/ui/authentication/screens/login_screen.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _RealSockets extends HttpOverrides {}

class _TestPaths extends PathProviderWindows {
  _TestPaths(this.directory);
  final String directory;
  @override
  Future<String> getApplicationSupportPath() async => directory;
}

class _Loopback extends http.BaseClient {
  _Loopback(SecurityContext? certificates)
      : _client = IOClient(_RealSockets().createHttpClient(certificates)
          ..findProxy = (_) => 'DIRECT');

  final IOClient _client;
  final passwordResponses = <int>[];
  final logoutResponses = <int>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.origin != SupabaseConfig.url) {
      throw StateError('Expected the dedicated local backend');
    }
    request.followRedirects = false;
    final response = await _client.send(request);
    if (request.url.path == '/auth/v1/token' &&
        request.url.queryParameters['grant_type'] == 'password') {
      passwordResponses.add(response.statusCode);
    }
    if (request.url.path == '/auth/v1/logout') {
      logoutResponses.add(response.statusCode);
    }
    return response;
  }

  @override
  void close() => _client.close();
}

void main() {
  final configA = Platform.environment['STUDENT_AUTH_LOCAL_FIRST'];
  final configB = Platform.environment['STUDENT_AUTH_LOCAL_SECOND'];
  final workspacePath = Platform.environment['STUDENT_AUTH_LOCAL_STATE'];
  final restoring =
      Platform.environment['STUDENT_AUTH_LOCAL_PHASE'] == 'restore';
  if (configA != null && configB != null && workspacePath != null) {
    LiveTestWidgetsFlutterBinding().framePolicy =
        LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  }
  testWidgets(
      restoring
          ? 'fresh process restores the signed-in student and signs out'
          : 'guest signs in, signs out and signs in as another student',
      (tester) async {
    const origin = SupabaseConfig.url;
    const tlsOrigin = 'https://127.0.0.1:55443';
    if (origin != tlsOrigin) {
      throw StateError('Use the isolated loopback Supabase with --dart-define');
    }
    final accounts = [
      for (final path in [configA!, configB!])
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>
    ];
    expect(accounts[0]['recipientId'] == accounts[1]['recipientId'], isFalse);
    final certificates = SecurityContext()
      ..setTrustedCertificates(Platform.environment['STUDENT_AUTH_LOCAL_CA']!);
    final transport = _Loopback(certificates);
    final dir = Directory(workspacePath!);
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
      ..pathProvider = _TestPaths(dir.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => dir.path);
    for (final channel in [
      'com.llfbandit.app_links/events',
      'keyboard_image_channel'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(channel), (_) async => null);
    }
    await initializeDateFormatting('ru');
    await app.debugInitializeOrdinaryApp(
        client: transport,
        databasePath: dir.path,
        databaseFactory: databaseFactoryFfi);
    final auth = Supabase.instance.client.auth;
    final submit = find.widgetWithText(FilledButton, 'Войти');
    final fields = find.byType(TextFormField);
    final workspace = find.byType(NavigationScreen);
    Future<void> until(bool Function() check, String reason) async {
      for (var frame = 0; frame < 160 && !check(); frame++) {
        await tester.pump(const Duration(milliseconds: 45));
      }
      expect(check(), isTrue, reason: reason);
    }

    Future<void> tap(Finder finder) async {
      await until(
          () => finder.evaluate().isNotEmpty, 'Missing control $finder');
      await tester.ensureVisible(finder.first);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(finder.first);
      await tester.pump(const Duration(milliseconds: 350));
    }

    bool home(bool guest) =>
        workspace.evaluate().length == 1 &&
        tester.widget<NavigationScreen>(workspace).guest == guest;
    Future<void> enterFromGuest() async {
      await until(() => home(true), 'Guest shell did not open');
      await tap(find.text('Профиль'));
      await tap(find.byTooltip('Войти'));
      await tap(find.widgetWithText(OutlinedButton, 'Войти'));
      await until(
          () => fields.evaluate().length == 2, 'Credential form did not open');
    }

    Future<void> credentials(String login, String password) async {
      await tester.enterText(fields.at(0), login);
      await tester.enterText(fields.at(1), password);
      tester.testTextInput.hide();
      await tester.ensureVisible(submit);
      await tester.pump(const Duration(milliseconds: 250));
    }

    Future<void> confirmAccount(Map<String, dynamic> account) async {
      await until(() => home(false), 'Signed-in home did not open');
      expect(auth.currentUser?.id == account['recipientId'], isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
          jsonDecode(prefs.getString('user')!)['id'] == account['recipientId'],
          isTrue);
    }

    Future<void> logout() async {
      await tap(find.text('Профиль'));
      await tap(find.byTooltip('Выйти'));
      await until(() => home(true) && auth.currentUser == null,
          'Logout did not return to guest');
      expect(
          transport.logoutResponses
              .where((status) => status >= 200 && status < 300),
          hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user'), isNull);
    }

    try {
      await tester.pumpWidget(const app.StudentPlatformApp());
      if (restoring) {
        await confirmAccount(accounts[1]);
        expect(transport.passwordResponses, isEmpty);
        await logout();
        return;
      }
      await enterFromGuest();
      await tap(submit);
      expect(find.text('Введите логин'), findsOneWidget);
      expect(find.text('Минимум 4 символа'), findsOneWidget);
      expect(transport.passwordResponses, isEmpty);

      await credentials(accounts[0]['login'], 'invalid-test-password');
      await tap(submit);
      await until(() => transport.passwordResponses.isNotEmpty,
          'Password RPC not reached');
      expect(transport.passwordResponses.single, inInclusiveRange(400, 499));
      expect(auth.currentUser, isNull);
      await until(() => find.byType(SnackBar).evaluate().isNotEmpty,
          'Missing login error');
      expect(find.text('Неверный логин или пароль.'), findsOneWidget);

      await credentials(accounts[0]['login'], accounts[0]['password']);
      final transitions =
          AuthTransitionHost.maybeRead(tester.element(fields.first))!;
      await tester.tap(submit);
      await tester.tap(submit);
      await confirmAccount(accounts[0]);
      await transitions.run(() async {});
      expect(transport.passwordResponses.where((status) => status == 200),
          hasLength(1));

      await logout();

      await enterFromGuest();
      await credentials(accounts[1]['email'], accounts[1]['password']);
      await tap(submit);
      await confirmAccount(accounts[1]);
      await until(() => find.byType(LoginScreen).evaluate().isEmpty,
          'The settled route still shows the login form');
      expect(transport.passwordResponses.where((status) => status == 200),
          hasLength(2));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await Supabase.instance.client.realtime.disconnect();
      await Supabase.instance.dispose();
      debugDefaultTargetPlatformOverride = null;
      transport.close();
    }
  }, skip: configA == null || configB == null || workspacePath == null);
}
