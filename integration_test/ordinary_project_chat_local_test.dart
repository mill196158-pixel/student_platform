import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/auth_transition_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/authentication/screens/login_screen.dart';
import 'package:student_platform/src/ui/info/subject_info_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/files_tab.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/local_schema_http_client.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final raw = Platform.environment['STUDENT_PROJECT_CHAT_LOCAL'];
  if (raw == null) {
    test('requires the isolated project-chat fixture', () {}, skip: true);
    return;
  }
  testWidgets(
      '036 opens the course-project PDF from materials and restores both routes',
      (t) async {
    final cfg = jsonDecode(raw) as Map<String, dynamic>;
    expect(cfg['schema'], matches(RegExp(r'^e2e_projectchat_[a-f0-9]{12}$')));
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    final http = LocalSchemaHttpClient(cfg['restPort'] as int);
    await Supabase.initialize(
        url: localSupabaseUrl,
        publishableKey: cfg['anon'] as String,
        httpClient: http,
        postgrestOptions:
            PostgrestClientOptions(schema: cfg['schema'] as String),
        authOptions: const FlutterAuthClientOptions(
            localStorage: EmptyLocalStorage(),
            autoRefreshToken: false,
            detectSessionInUri: false));
    final sb = Supabase.instance.client;
    File? verifiedExport;
    try {
      await t.pumpWidget(AuthTransitionHost(
          child: AuthSessionScopeHost(
              child: MaterialApp(
        theme: AppTheme.light().data,
        home: LoginScreen(toggleView: () {}),
        routes: {'/home': (_) => const NavigationScreen()},
      ))));
      Future<void> wait(bool Function() ready, String label) async {
        final timer = Stopwatch()..start();
        while (!ready() && timer.elapsed < const Duration(seconds: 20)) {
          await t.pump(const Duration(milliseconds: 65));
        }
        if (!ready()) {
          final texts = find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .whereType<String>()
              .join(' | ');
          fail('$label. Visible text: $texts');
        }
      }

      Future<void> tap(Finder f) async {
        await wait(() => f.evaluate().isNotEmpty,
            'Could not find ${f.describeMatch(Plurality.zero)}');
        await t.ensureVisible(f.first);
        await t.pump(const Duration(milliseconds: 150));
        await wait(() => f.hitTestable().evaluate().isNotEmpty,
            'Not accessible: ${f.describeMatch(Plurality.one)}');
        await t.tap(f.hitTestable().first);
        await t.pump(const Duration(milliseconds: 400));
      }

      Future<void> showSubjectAction(String label) async {
        final subject = find.byType(SubjectInfoScreen);
        final scrollable = find
            .descendant(of: subject, matching: find.byType(Scrollable))
            .first;
        await t.scrollUntilVisible(
            find.descendant(of: subject, matching: find.text(label)), 200,
            scrollable: scrollable, maxScrolls: 25);
        await t.pump(const Duration(milliseconds: 150));
      }

      Future<void> back() async {
        expect(await t.binding.handlePopRoute(), isTrue);
        await t.pump(const Duration(milliseconds: 400));
        await t.pump(const Duration(milliseconds: 100));
      }

      await t.enterText(find.byType(TextFormField).at(0),
          cfg['email'].toString().split('@').first);
      await t.enterText(
          find.byType(TextFormField).at(1), cfg['password'] as String);
      await tap(find.widgetWithText(FilledButton, 'Войти'));
      await wait(() => find.byType(NavigationScreen).evaluate().isNotEmpty,
          'Student home did not open');
      expect(sb.auth.currentUser!.id, cfg['student']);
      await tap(find.text('База'));
      await tap(find.text('Курсовой проект и практика'));
      await wait(() => find.text('Чат').evaluate().isNotEmpty,
          'Regular course should have the ordinary action');
      await showSubjectAction('Чат предмета');
      expect(find.text('Чат курсового проекта'), findsNothing);
      expect(
          t
              .widget<SubjectInfoScreen>(find.byType(SubjectInfoScreen))
              .subjectOfferingId,
          cfg['off_control']);
      await back();
      await tap(find.text('Сопромат'));
      final projectInfo = find.byType(SubjectInfoScreen);
      await wait(() => find.text('Чат проекта').evaluate().isNotEmpty,
          'Missing action for course_project in plan');
      final subjectRoute = ModalRoute.of(t.element(projectInfo));
      expect(t.widget<SubjectInfoScreen>(projectInfo).subjectOfferingId,
          cfg['off_project']);
      await showSubjectAction('Чат курсового проекта');
      final projectChat = find.text('Чат курсового проекта').hitTestable();
      final target = t.getCenter(projectChat);
      await t.tapAt(target);
      await t.tapAt(target);
      await t.pump(const Duration(milliseconds: 400));
      final team = find.byType(TeamDetailsScreen);
      await wait(
          () => find.text('Расчёт моста: проект 036').evaluate().isNotEmpty,
          'Wrong chat history');
      expect(
          find.byType(TeamDetailsScreen, skipOffstage: false), findsOneWidget);
      expect(t.widget<TeamDetailsScreen>(team).team.id, cfg['team_project']);
      final teamRoute = ModalRoute.of(t.element(team));
      await tap(find.text('Файлы'));
      final panel = find.byType(FilesTab);
      await tap(find.descendant(of: panel, matching: find.text('Файлы')));
      final file = find.descendant(
          of: panel, matching: find.text('Расчётная записка.pdf'));
      await tap(file);
      final preview = find.byType(FullscreenFileViewer);
      await wait(() => preview.evaluate().isNotEmpty, 'Preview missing');
      final viewer = t.widget<FullscreenFileViewer>(preview);
      expect(viewer.sourceFileId, cfg['file_project']);
      expect(viewer.sourceFile!.chatId, cfg['chat_project']);
      final pdf = find.byType(PdfViewer);
      await wait(() => pdf.evaluate().isNotEmpty,
          'Native PDF renderer failed to open project file');
      final ref = t.widget<PdfViewer>(pdf).documentRef as PdfDocumentRefFile;
      final export = File(ref.file);
      expect(sha256.convert(await export.readAsBytes()).toString(),
          cfg['pdfHash']);
      verifiedExport = export;
      print(
          'PASS ordinary login, materials, actual course assessment, exact team, native PDF and SHA-256');
      await back();
      await wait(
          () =>
              teamRoute!.isCurrent &&
              find
                  .byType(FullscreenFileViewer, skipOffstage: false)
                  .evaluate()
                  .isEmpty &&
              file.hitTestable().evaluate().isNotEmpty,
          'First Back did not restore Files and dispose the preview');
      expect(ModalRoute.of(t.element(team)), same(teamRoute));
      await back();
      await wait(
          () =>
              subjectRoute!.isCurrent &&
              find
                  .byType(TeamDetailsScreen, skipOffstage: false)
                  .evaluate()
                  .isEmpty,
          'Second Back did not restore the original subject and dispose the chat');
      expect(t.widget<SubjectInfoScreen>(projectInfo).subjectOfferingId,
          cfg['off_project']);
      expect(find.byType(TeamDetailsScreen, skipOffstage: false), findsNothing);
      expect(
          find.byType(SubjectInfoScreen, skipOffstage: false), findsOneWidget);
      print(
          'PASS 036 two system Back requests restored the original files tab then the original course, with one route each');
    } finally {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(milliseconds: 350));
      await sb.auth.signOut(scope: SignOutScope.local);
      await Supabase.instance.dispose();
      http.close();
      if (verifiedExport != null && await verifiedExport.exists()) {
        await verifiedExport.delete();
      }
    }
  });
}
