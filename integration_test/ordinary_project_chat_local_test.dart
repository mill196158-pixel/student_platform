import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/auth_transition_host.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/navigation/group_action_deeplink.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/selection_bars.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_gate.dart';
import 'package:student_platform/src/ui/authentication/screens/login_screen.dart';
import 'package:student_platform/src/ui/info/subject_info_screen.dart';
import 'package:student_platform/src/ui/learning/team_details_screen.dart';
import 'package:student_platform/src/ui/learning/tabs/files_tab.dart';
import 'package:student_platform/src/ui/learning/widgets/fullscreen_image.dart';
import 'package:student_platform/src/ui/navigation/navigation_screen.dart';
import 'package:student_ui/student_ui.dart' show StudentBottomNav;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/local_schema_http_client.dart';

class _HeldMembership {
  _HeldMembership(this.teamId);

  final String teamId;
  final received = Completer<void>();
  final release = Completer<void>();
}

class _ProjectChatHttpClient extends LocalSchemaHttpClient {
  _ProjectChatHttpClient(super.port, {this.recordCapabilities = false});

  final bool recordCapabilities;
  final capabilityResponses = <({String chatId, String? proposeReason})>[];
  _HeldMembership? holdMembership;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final held = holdMembership;
    if (held != null &&
        request.url.path == '/rest/v1/team_members' &&
        request.url.queryParameters['select'] == 'team_id,user_id' &&
        request.url.queryParameters['team_id'] == 'eq.${held.teamId}') {
      holdMembership = null;
      final response = await super.send(request);
      final bytes = await response.stream.toBytes();
      held.received.complete();
      await held.release.future;
      return http.StreamedResponse(Stream.value(bytes), response.statusCode,
          headers: response.headers, request: request);
    }
    final response = await super.send(request);
    if (!recordCapabilities ||
        request is! http.Request ||
        request.url.path != '/rest/v1/rpc/get_chat_composer_capabilities' ||
        response.statusCode != 200) {
      return response;
    }
    final bytes = await response.stream.toBytes();
    final params = jsonDecode(request.body) as Map<String, dynamic>;
    final capabilities = jsonDecode(utf8.decode(bytes));
    if (capabilities is Map<String, dynamic>) {
      final reasons = capabilities['reasons'];
      capabilityResponses.add((
        chatId: params['p_chat_id'] as String,
        proposeReason: reasons is Map ? reasons['propose_assignment'] as String? : null,
      ));
    }
    return http.StreamedResponse(Stream.value(bytes), response.statusCode,
        headers: response.headers, request: request);
  }
}

typedef _WaterCourse = ({String key, String title, String history,
  String teamId, String chatId, String offeringId, String linkMessageId,
  String subjectAction});

Future<void> _verifyWaterChatRoutes(
  WidgetTester tester,
  Map<String, dynamic> config,
  SupabaseClient client,
  _ProjectChatHttpClient transport,
  Future<void> Function(bool Function(), String) wait,
  Future<void> Function(Finder) tap,
  Future<void> Function() back,
  Future<void> Function(String) showSubjectAction,
) async {
  final account = config['student'] as String;
  final _WaterCourse reliability = (
    key: 'reliability',
    title: 'Надежность систем водоснабжения и водоотведения',
    history: 'История Надежности водоснабжения',
    teamId: config['team_project'] as String,
    chatId: config['chat_project'] as String,
    offeringId: config['off_project'] as String,
    linkMessageId: config['link_to_project'] as String,
    subjectAction: 'Чат курсового проекта',
  );
  final _WaterCourse modeling = (
    key: 'modeling',
    title: 'Моделирование систем водоснабжения и водоотведения',
    history: 'История Моделирования водоснабжения',
    teamId: config['team_control'] as String,
    chatId: config['chat_control'] as String,
    offeringId: config['off_control'] as String,
    linkMessageId: config['link_to_control'] as String,
    subjectAction: 'Чат предмета',
  );
  final courses = [reliability, modeling];

  Finder currentTeam(_WaterCourse course) => find.byElementPredicate((element) {
        final widget = element.widget;
        return widget is TeamDetailsScreen &&
            widget.team.id == course.teamId &&
            ModalRoute.isCurrentOf(element) == true;
      });
  Finder inside(Finder route, Finder child) =>
      find.descendant(of: route, matching: child);
  Finder navTab(String name) => inside(find.byType(StudentBottomNav), find.text(name));
  Finder inboxRow(_WaterCourse course) =>
      find.byKey(ValueKey<String>(course.chatId));
  Finder messageLink(_WaterCourse course) =>
      find.byKey(ValueKey('team-chat-message-link:${course.chatId}'));

  Future<void> checkWritable(
    _WaterCourse course,
    String path,
    Future<void> Function() open,
  ) async {
    final previousReplies = transport.capabilityResponses.length;
    final held = _HeldMembership(course.teamId);
    transport.holdMembership = held;
    final route = currentTeam(course);
    final composer = inside(route, find.byType(EditableText));
    final historyList = inside(route, find.byType(ChatMessageList));
    try {
      await open();
      await wait(() => route.evaluate().isNotEmpty,
          '${course.title}: wrong team via $path');
      expect(tester.widget<TeamDetailsScreen>(route).readOnly, isFalse);
      expect(client.auth.currentUser!.id, account);
      await wait(() => held.received.isCompleted,
          '${course.title}: did not check independent membership via $path');
      expect(composer, findsNothing);
      expect(inside(route, find.text('Подключение к чату…')), findsOneWidget);
      await wait(() => inside(route, find.text(course.history)).evaluate().isNotEmpty,
          '${course.title}: expected original history via $path');
      final before = tester.getRect(historyList);
      expect(tester.widget<ChatMessageList>(historyList).messages
          .singleWhere((message) => message.text == course.history).chatId, course.chatId);

      held.release.complete();
      await wait(() => composer.hitTestable().evaluate().isNotEmpty,
          '${course.title}: editor after positive membership via $path');
      expect(tester.getRect(historyList).top, closeTo(before.top, 1));
      expect(tester.getRect(historyList).bottom, closeTo(before.bottom, 1));
      await wait(
        () => transport.capabilityResponses.skip(previousReplies).any(
          (reply) => reply.chatId == course.chatId && reply.proposeReason == 'not_member',
        ),
        '${course.title}: missing fresh composer capabilities via $path',
      );

      final text = 'QA water ${course.key} $path';
      await tester.enterText(composer, text);
      final send = inside(route, find.byTooltip('Отправить')).hitTestable();
      expect(send, findsOneWidget);
      await tester.tap(send);
      await wait(() => tester.widget<EditableText>(composer).controller.text.isEmpty,
          '${course.title}: message not confirmed via $path');
      final rows = await client.from('messages')
          .select('chat_id,author_id').eq('body', text);
      expect(rows, [{'chat_id': course.chatId, 'author_id': account}]);
      print('PASS water chat ${course.key} via $path '
          'account=$account team=${course.teamId} chat=${course.chatId} '
          'readOnly=false propose_assignment=not_member send=allowed');
    } finally {
      if (!held.release.isCompleted) held.release.complete();
      if (identical(transport.holdMembership, held)) transport.holdMembership = null;
    }
  }

  await tap(navTab('Обучение'));
  for (final course in courses) {
    await checkWritable(course, 'learning-menu', () => tap(find.text(course.title)));
    await back();
  }

  await tap(navTab('База'));
  for (final course in courses) {
    await tap(find.text(course.title));
    expect(tester.widget<SubjectInfoScreen>(find.byType(SubjectInfoScreen))
        .subjectOfferingId, course.offeringId);
    await showSubjectAction(course.subjectAction);
    await checkWritable(course, 'materials', () => tap(find.text(course.subjectAction)));
    await back();
    await back();
  }

  await tap(navTab('Профиль'));
  final openInbox = find.text('Сообщения');
  for (final course in courses) {
    await tap(openInbox);
    await checkWritable(course, 'inbox', () => tap(inboxRow(course)));
    await back();
  }

  for (final (source, target) in [(modeling, reliability), (reliability, modeling)]) {
    await tap(openInbox);
    await tap(inboxRow(source));
    final sourceRoute = currentTeam(source);
    await wait(() => inside(sourceRoute, messageLink(target)).hitTestable()
        .evaluate().isNotEmpty, 'Persisted link in ${source.title}');
    final history = inside(sourceRoute, find.byType(ChatMessageList));
    final message = tester.widget<ChatMessageList>(history).messages
        .singleWhere((row) => row.id == target.linkMessageId);
    expect(message.chatId, source.chatId);
    expect(message.text, contains('studentplatform://chat/${target.chatId}'));
    await checkWritable(target, 'message-link', () => tap(inside(sourceRoute, messageLink(target))));
    await back();
    expect(sourceRoute, findsOneWidget);
    await back();
  }

  // Revoke only the disposable student's membership to check the denial path.
  // The ordinary list policy still allows reading the enrolled subject.
  await client.rpc('fixture_deny_project_writes');
  await tap(openInbox);
  await tap(inboxRow(modeling));
  final source = currentTeam(modeling);
  await tap(inside(source, messageLink(reliability)));
  await wait(() => find.text('Этот чат вам недоступен').evaluate().isNotEmpty,
      'Revoked membership must deny the inline link');
  expect(source, findsOneWidget);
  expect(currentTeam(reliability), findsNothing);
  await back();

  await tap(openInbox);
  await tap(inboxRow(reliability));
  final readOnly = currentTeam(reliability);
  await wait(() => inside(readOnly, find.text('Только чтение. Отправка недоступна.'))
      .evaluate().isNotEmpty, 'Readable history without write membership');
  expect(inside(readOnly, find.text(reliability.history)), findsOneWidget);
  expect(inside(readOnly, find.byType(EditableText)), findsNothing);
  print('PASS water chat denied link and read-only account=$account chat=${reliability.chatId}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final raw = Platform.environment['STUDENT_PROJECT_CHAT_LOCAL'];
  if (raw == null) {
    test('requires the isolated project-chat fixture', () {}, skip: true);
    return;
  }
  final cfg = jsonDecode(raw) as Map<String, dynamic>;
  final water = cfg['water'] == true;
  testWidgets(water
      ? 'Water-supply teams from menu, inbox and persisted message links'
      : '036 opens the course-project PDF from materials and restores both routes',
      (t) async {
    expect(cfg['schema'], matches(RegExp(
        water ? r'^e2e_waterchat_[a-f0-9]{12}$' : r'^e2e_projectchat_[a-f0-9]{12}$')));
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(390, 844);
    t.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetPadding);
    addTearDown(t.view.resetViewInsets);
    await initializeDateFormatting('ru');
    SharedPreferences.setMockInitialValues({});
    final transport = _ProjectChatHttpClient(cfg['restPort'] as int, recordCapabilities: water);
    await Supabase.initialize(
        url: localSupabaseUrl,
        publishableKey: cfg['anon'] as String,
        httpClient: transport,
        postgrestOptions:
            PostgrestClientOptions(schema: cfg['schema'] as String),
        authOptions: const FlutterAuthClientOptions(
            localStorage: EmptyLocalStorage(),
            autoRefreshToken: false,
            detectSessionInUri: false));
    final sb = Supabase.instance.client;
    File? verifiedExport;
    final captureBoundary = GlobalKey();
    var captureUnavailable = false;
    Future<void> capture(String name) async {
      final directory = Platform.environment['STUDENT_PROJECT_CAPTURES'];
      if (directory == null || captureUnavailable) return;
      final boundary = captureBoundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      Future<void> writeImage() async {
        final image = await boundary.toImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          if (!captureUnavailable) {
            await File('$directory/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          }
        } finally {
          image.dispose();
        }
      }
      try {
        await writeImage().timeout(const Duration(seconds: 4));
      } on TimeoutException {
        captureUnavailable = true;
        debugPrint('Optional native screenshot timed out: $name');
      }
    }

    try {
      await t.pumpWidget(AuthTransitionHost(
          child: AuthSessionScopeHost(
              child: ForwardOutboxHost(
                  child: MaterialApp(
        theme: AppTheme.light().data,
        builder: (_, child) =>
            RepaintBoundary(key: captureBoundary, child: child),
        home: LoginScreen(toggleView: () {}),
        routes: {'/home': (_) => const NavigationScreen()},
      )))));
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
      if (water) {
        await _verifyWaterChatRoutes(t, cfg, sb, transport, wait, tap, back, showSubjectAction);
        return;
      }
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
      final projectMessage = find.text('Расчёт моста: проект 036');
      await wait(() => projectMessage.hitTestable().evaluate().isNotEmpty,
          'The project message is visible');
      await wait(
          () => find.byType(EditableText).hitTestable().evaluate().isNotEmpty,
          'Project composer is ready');
      final messageRect = t.getRect(projectMessage);
      await t.longPress(projectMessage.hitTestable());
      await tap(find.text('Выбрать'));
      expect(find.text('Выбрано 1'), findsOneWidget);
      expect(find.byType(BottomSelectionBar), findsOneWidget);
      final selectedRect = t.getRect(projectMessage);
      expect(selectedRect.size, messageRect.size);
      expect(selectedRect.center.dy, closeTo(messageRect.center.dy, 1));
      await t.dragFrom(selectedRect.center, const Offset(-240, 0));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Выбрано 1').hitTestable(), findsOneWidget);
      expect(t.getRect(projectMessage).center.dy, closeTo(messageRect.center.dy, 1));
      await capture('native-message-selection');
      await tap(find.byTooltip('Назад'));
      expect(find.byType(BottomSelectionBar), findsNothing);
      expect(t.getRect(projectMessage).center.dy,
          closeTo(messageRect.center.dy, 1));
      print(
          'PASS iPhone follow-up: long press > Выбрать preserves the project message through entry and exit');

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

      final nav = Navigator.of(t.element(projectInfo));
      nav.push<void>(MaterialPageRoute(
          builder: (_) => const MyChatsScreen(enableRealtime: false)));
      final catalog = find.byType(MyChatsScreen);
      Finder teamScreen(String key) => find.byElementPredicate((element) {
            final widget = element.widget;
            return widget is TeamDetailsScreen &&
                widget.team.id == cfg[key] &&
                ModalRoute.isCurrentOf(element) == true;
          });
      final targetTeam = teamScreen('team_project');
      final sourceTeam = teamScreen('team_control');
      Finder editor(Finder screen) =>
          find.descendant(of: screen, matching: find.byType(EditableText));
      final composer = editor(targetTeam);
      final viewport = find.descendant(
          of: targetTeam, matching: find.byType(ChatMessageList));
      final projectRow =
          find.byKey(ValueKey<String>(cfg['chat_project'] as String));
      bool isCurrent(Finder screen) => screen.evaluate().isNotEmpty;
      Future<void> waitForProject() =>
          wait(() => isCurrent(targetTeam), 'Target project chat');

      final slow = _HeldMembership(cfg['team_project'] as String);
      transport.holdMembership = slow;
      addTearDown(() {
        if (!slow.release.isCompleted) slow.release.complete();
      });
      await tap(projectRow);
      await waitForProject();
      await wait(() => slow.received.isCompleted, 'Held rights response');
      final connecting = find.text('Подключение к чату…');
      expect(connecting, findsOneWidget);
      expect(composer, findsNothing);
      final shortMessage = find.text('Расчёт моста: проект 036').hitTestable();
      await wait(
          () => shortMessage.evaluate().isNotEmpty, 'Readable short history');
      final initialMessageRect = t.getRect(shortMessage);
      final waitingViewport = t.getRect(viewport);
      await capture('native-chat-awaiting-write-rights');
      slow.release.complete();
      await wait(() => composer.hitTestable().evaluate().isNotEmpty,
          'Composer from list');
      final listRect = t.getRect(composer);
      expect(t.getRect(viewport).top, closeTo(waitingViewport.top, 1));
      expect(t.getRect(viewport).bottom, closeTo(waitingViewport.bottom, 1));
      expect(t.getRect(shortMessage).top, closeTo(initialMessageRect.top, 1));
      const sentText = 'Сообщение в чате без доступа к заданиям';
      await t.enterText(composer, sentText);
      final sendButton = find.byTooltip('Отправить').hitTestable();
      expect(sendButton, findsOneWidget);
      await t.tap(sendButton);
      await wait(() => find.text(sentText).hitTestable().evaluate().isNotEmpty,
          'Sent from the confirmed composer');
      await wait(() => t.widget<EditableText>(composer).controller.text.isEmpty,
          'The accepted send clears the editor');
      final sent = await sb
          .from('messages')
          .select('id,author_id')
          .eq('chat_id', cfg['chat_project'] as String)
          .eq('body', sentText);
      expect(sent, hasLength(1));
      expect(sent.single['author_id'], sb.auth.currentUser!.id);
      print(
          'PASS iPhone follow-up: slow rights and independent send preserve short history and reach the correct team');

      final tabs =
          find.descendant(of: targetTeam, matching: find.byType(TabBar));
      final header =
          find.descendant(of: targetTeam, matching: find.text('Сопромат'));
      final headerTop = t.getTopLeft(header).dy;
      final tabsTop = t.getTopLeft(tabs).dy;
      await capture('native-chat-header-before-focus');
      await t.tap(composer);
      t.view.viewInsets = const FakeViewPadding(bottom: 280);
      await t.pump(const Duration(milliseconds: 350));
      expect(t.getTopLeft(header).dy, closeTo(headerTop, 1));
      expect(t.getTopLeft(tabs).dy, closeTo(tabsTop, 1));
      expect(t.getTopLeft(viewport).dy, closeTo(waitingViewport.top, 1));
      expect(t.takeException(), isNull);
      await capture('native-chat-header-with-keyboard-inset');
      t.view.resetViewInsets();
      await t.pump(const Duration(milliseconds: 250));
      await back();
      await wait(() => catalog.hitTestable().evaluate().isNotEmpty,
          'Return to chat list');

      await sb.rpc('fixture_seed_long_history');
      await tap(projectRow);
      await waitForProject();
      await wait(
          () => find
              .textContaining('История чата')
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'Long project history');
      final historyScrollable = find
          .descendant(of: viewport, matching: find.byType(Scrollable))
          .first;
      final scrolling = t.state<ScrollableState>(historyScrollable).position;
      await t.drag(historyScrollable, const Offset(0, 240));
      await t.pump(const Duration(milliseconds: 500));
      expect(scrolling.pixels, greaterThan(150));
      final olderPosition = scrolling.pixels;
      final anchor = find.textContaining('История чата').hitTestable().first;
      final anchorLabel = t.widget<Text>(anchor).data!;
      final exactAnchor = find.text(anchorLabel).hitTestable();
      final anchorTop = t.getTopLeft(exactAnchor).dy;
      await t.tap(exactAnchor);
      await t.pump(const Duration(milliseconds: 250));
      expect(t.getTopLeft(tabs).dy, closeTo(tabsTop, 1));
      expect(t.getTopLeft(exactAnchor).dy, closeTo(anchorTop, 1));
      await tap(find.descendant(of: tabs, matching: find.text('Файлы')));
      await wait(
          () => find.byType(FilesTab).hitTestable().evaluate().isNotEmpty,
          'Files tab');
      expect(t.getTopLeft(tabs).dy, closeTo(tabsTop, 1));
      await tap(find.descendant(of: tabs, matching: find.text('Чат')));
      await wait(() => exactAnchor.evaluate().isNotEmpty,
          'Return to previous history anchor');
      expect(t.getTopLeft(exactAnchor).dy, closeTo(anchorTop, 1));
      expect(scrolling.pixels, closeTo(olderPosition, 1));
      await t.drag(historyScrollable, const Offset(0, -210));
      await t.pump(const Duration(milliseconds: 500));
      expect(scrolling.pixels, lessThan(olderPosition));
      expect(t.getTopLeft(header).dy, closeTo(headerTop, 1));
      await capture('native-chat-long-history-after-files');
      print(
          'PASS iPhone follow-up: header and history stable under focus, a message tap, both scroll directions and returning from files');
      await back();
      await wait(() => catalog.hitTestable().evaluate().isNotEmpty,
          'Return from long chat');

      final emptyTeam = teamScreen('team_empty');
      final emptyEditor = editor(emptyTeam);
      final emptyRow =
          find.byKey(ValueKey<String>(cfg['chat_empty'] as String));
      final emptyMessages = await sb
          .from('messages')
          .select('id')
          .eq('chat_id', cfg['chat_empty'] as String);
      expect(emptyMessages, isEmpty);
      await tap(emptyRow);
      await wait(
          () =>
              isCurrent(emptyTeam) &&
              emptyEditor.hitTestable().evaluate().isNotEmpty,
          'Empty team is independently writable');
      await wait(() => find.text('Сообщений пока нет').evaluate().isNotEmpty,
          'Confirmed empty history');
      expect(find.text('Напишите первое сообщение.'), findsOneWidget);
      final emptyTeamModel = t.widget<TeamDetailsScreen>(emptyTeam).team;
      await back();
      await wait(() => catalog.hitTestable().evaluate().isNotEmpty,
          'Return from empty chat');
      await sb.rpc('fixture_archive_empty_chat');
      unawaited(nav.push<void>(MaterialPageRoute(
          builder: (_) => TeamDetailsScreen(team: emptyTeamModel))));
      await wait(
          () =>
              isCurrent(emptyTeam) &&
              find
                  .text('Только чтение. Отправка недоступна.')
                  .evaluate()
                  .isNotEmpty,
          'Archive lookup excludes an otherwise eligible member');
      expect(emptyEditor, findsNothing);
      await back();
      await wait(() => catalog.hitTestable().evaluate().isNotEmpty,
          'Return from archived chat');
      unawaited(nav.push<void>(MaterialPageRoute(
          builder: (_) =>
              TeamDetailsScreen(team: emptyTeamModel, readOnly: true))));
      await wait(
          () =>
              isCurrent(emptyTeam) &&
              find
                  .text('Только чтение. Семестр завершён.')
                  .evaluate()
                  .isNotEmpty,
          'Completed-semester route remains read-only');
      expect(emptyEditor, findsNothing);
      print(
          'PASS iPhone follow-up: empty active and archived teams honor both exact send and semester route access');
      await back();
      await wait(() => catalog.hitTestable().evaluate().isNotEmpty,
          'Return from completed semester');

      await tap(find.byKey(ValueKey<String>(cfg['chat_control'] as String)));
      await wait(
          () =>
              find.text('Обычный чат 036').hitTestable().evaluate().isNotEmpty,
          'Source message');
      await wait(() => editor(sourceTeam).hitTestable().evaluate().isNotEmpty,
          'Source composer');
      await t.longPress(find.text('Обычный чат 036').hitTestable());
      await tap(find.text('Переслать'));
      await tap(find.widgetWithText(ListTile, 'Сопромат'));
      expect(find.text('Кому: Сопромат'), findsOneWidget);
      await capture('native-forward-recipient');
      await t.tap(find.widgetWithText(FilledButton, 'Продолжить'));
      await waitForProject();
      expect(
          find.descendant(
              of: targetTeam, matching: find.byType(ChatComposerGate)),
          findsOneWidget);
      await wait(
          () => viewport.evaluate().isNotEmpty, 'Initial project viewport');
      final initialViewport = t.getRect(viewport);
      await wait(() => composer.hitTestable().evaluate().isNotEmpty,
          'Forward destination composer');
      expect(t.getRect(composer).bottom, closeTo(listRect.bottom, 1));
      await wait(
          () => find.byTooltip('Отменить пересылку').evaluate().isNotEmpty,
          'Forward draft');
      expect(t.getRect(viewport).top, closeTo(initialViewport.top, 1));
      print(
          'PASS iPhone follow-up: list and forward open the same writable team with the composer at the same bottom edge');

      // Exercise the next opening with an authoritative response denying writes.
      // History remains available throughout so the denial has a visible state.
      await back();
      await wait(() => isCurrent(sourceTeam), 'Return to source chat');
      final targetMessage = await sb
          .from('messages')
          .select('id')
          .eq('chat_id', cfg['chat_project'] as String)
          .eq('body', 'Расчёт моста: проект 036')
          .single();
      final sourceMessage = find.text('Обычный чат 036').hitTestable();
      await wait(
          () => sourceMessage.evaluate().isNotEmpty, 'Visible source message');
      void openProjectDeeplink() => unawaited(openGroupActionDeeplink(
          t.element(sourceMessage),
          GroupActionDeeplinkArgs(
            chatId: cfg['chat_project'] as String,
            cardMessageId: targetMessage['id'] as String,
            entityType: 'message',
            entityId: '',
          )));
      final stale = _HeldMembership(cfg['team_project'] as String);
      transport.holdMembership = stale;
      addTearDown(() {
        if (!stale.release.isCompleted) stale.release.complete();
      });
      openProjectDeeplink();
      await waitForProject();
      await wait(
          () => stale.received.isCompleted, 'Captured old positive rights');
      expect(composer, findsNothing);
      await back();
      await wait(() => isCurrent(sourceTeam), 'Leave pending route');
      await sb.rpc('fixture_deny_project_writes');
      openProjectDeeplink();
      await waitForProject();
      await wait(
          () => find
              .text('Только чтение. Отправка недоступна.')
              .evaluate()
              .isNotEmpty,
          'Accessible read-only state');
      expect(composer, findsNothing);
      stale.release.complete();
      await t.pump(const Duration(milliseconds: 500));
      expect(composer, findsNothing);
      expect(find.text('Только чтение. Отправка недоступна.'), findsOneWidget);
      await wait(
          () => find.text('Расчёт моста: проект 036').evaluate().isNotEmpty,
          'History remains available for reading');
      await capture('native-read-only-team');
      print(
          'PASS iPhone follow-up: composer denied after a stale positive response, existing team history readable');
    } finally {
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(milliseconds: 350));
      await sb.auth.signOut(scope: SignOutScope.local);
      await Supabase.instance.dispose();
      transport.close();
      if (verifiedExport != null && await verifiedExport.exists()) {
        await verifiedExport.delete();
      }
    }
  });
}
