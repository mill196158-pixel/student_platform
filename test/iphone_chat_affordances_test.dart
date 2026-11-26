import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/chats/forward/forward_picker.dart';
import 'package:student_platform/src/ui/chats/my_chats_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_platform/src/ui/learning/state/team_cubit.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/actions/chat_actions.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';

import 'chat_file_durable_receipt_test.dart' show signInWithFileSession;

const _owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _chatId = '11111111-1111-4111-8111-111111111111';
const _teamId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void portrait(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  Future<void> initSupabase(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(links, null));
    await tester.runAsync(() async {
      await Supabase.initialize(
        url: 'https://example.test',
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          final data = request.url.path.endsWith('/get_my_chat_summaries')
              ? [
                  {
                    'chat_id': _chatId,
                    'chat_type': 'team_main',
                    'team_id': _teamId,
                    'team_name': 'Проектная команда',
                    'title': 'Проектная команда',
                    'settings_exists': true,
                    'unread_count': 0,
                    'last_message_at': '2026-01-01T00:00:00Z',
                  }
                ]
              : const [];
          return http.Response(jsonEncode(data), 200,
              request: request, headers: {'content-type': 'application/json'});
        }),
      );
      await signInWithFileSession(Supabase.instance.client, 'owner', _owner);
    });
    addTearDown(() async => Supabase.instance.dispose());
  }

  testWidgets('composer keeps its footprint while the session is pending',
      (tester) async {
    portrait(tester);
    final status = ValueNotifier<String?>('Подключение к чату…');
    final input = FocusNode();
    final controller = TextEditingController();
    addTearDown(status.dispose);
    addTearDown(input.dispose);
    addTearDown(controller.dispose);
    var sends = 0;

    const viewport = Key('short-chat-viewport');
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox(key: viewport)),
            ValueListenableBuilder(
              valueListenable: status,
              builder: (_, state, __) => ChatComposerGate(
                status: state,
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                          child: TextField(
                              controller: controller, focusNode: input)),
                      IconButton(
                          onPressed: () => sends++,
                          icon: const Icon(Icons.send)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ));
    final before = tester.getRect(find.byKey(viewport));
    expect(find.text('Подключение к чату…'), findsOneWidget);
    expect(find.byType(TextField).hitTestable(), findsNothing);
    await tester.tapAt(tester.getCenter(find.byType(TextField)));
    expect(input.hasFocus, isFalse);
    expect(sends, 0);
    status.value = null;
    await tester.pump();
    expect(tester.getRect(find.byKey(viewport)), before);
    await tester.enterText(find.byType(TextField), 'Готово');
    await tester.tap(find.byIcon(Icons.send));
    expect(sends, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first outside tap dismisses a long-press menu without actions',
      (tester) async {
    portrait(tester);
    await initSupabase(tester);
    const team = Team(
        id: _teamId,
        name: 'Проектная команда',
        teacher: '',
        groupCode: '',
        icon: '📚');
    final cubit = TeamCubit(team);
    final message = Message(
        id: 'm1',
        chatId: _chatId,
        authorId: 'peer',
        authorLogin: 'peer',
        authorName: 'Собеседник',
        text: 'Открыть меню',
        at: DateTime(2026, 11, 25));
    addTearDown(cubit.close);
    var menuActions = 0;
    var sourceTaps = 0;
    final destinations = <ForwardTarget?>[];
    Future<void> waitForRecipient() async {
      for (var i = 0;
          i < 80 && find.text('Проектная команда').evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      expect(find.text('Проектная команда'), findsOneWidget);
    }

    await tester.pumpWidget(AuthSessionScopeHost(
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: BlocProvider.value(
          value: cubit,
          child: Scaffold(body: Builder(builder: (context) {
            void countAction() => menuActions++;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => sourceTaps++,
              child: Stack(
                children: [
                  const SizedBox.expand(),
                  Positioned(
                    left: 24,
                    top: 200,
                    child: Builder(builder: (bubbleContext) {
                      return GestureDetector(
                        onLongPress: () {
                          final box =
                              bubbleContext.findRenderObject()! as RenderBox;
                          ChatActions.showMessageActions(
                            context,
                            message,
                            targetRect:
                                box.localToGlobal(Offset.zero) & box.size,
                            onReply: countAction,
                            onForward: () async {
                              countAction();
                              final result = await Navigator.of(context)
                                  .push<ForwardTarget>(
                                MaterialPageRoute(
                                    builder: (_) => MyChatsScreen(
                                          pickMode: true,
                                          pickIsCurrent: () => true,
                                          enableRealtime: false,
                                        )),
                              );
                              destinations.add(result);
                            },
                            onTogglePin: () async => countAction(),
                            onDeleteIfAllowed: () async => countAction(),
                            onReact: (_) => countAction(),
                            onSelect: countAction,
                          );
                        },
                        child: Text(message.text),
                      );
                    }),
                  ),
                ],
              ),
            );
          })),
        ),
      ),
    ));

    Future<void> openMenu() async {
      await tester.longPress(find.text(message.text).first);
      await tester.pumpAndSettle();
      expect(find.text('Переслать'), findsOneWidget);
    }

    await openMenu();
    await tester.tapAt(const Offset(378, 810));
    await tester.pumpAndSettle();
    expect(find.text('Переслать'), findsNothing);
    expect(menuActions, 0);
    expect(sourceTaps, 0);
    await openMenu();
    await tester.tapAt(const Offset(380, 28));
    await tester.pumpAndSettle();
    expect(find.text('Переслать'), findsNothing);
    expect(sourceTaps, 0);

    Future<void> choose() async {
      await openMenu();
      await tester.tap(find.text('Переслать'));
      await tester.pump();
      await waitForRecipient();
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Продолжить'))
              .onPressed,
          isNull);
      await tester.tap(find.text('Проектная команда').hitTestable());
      await tester.pump();
      final tile = tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Проектная команда'));
      expect(tile.selected, isTrue);
      expect(find.text('Кому: Проектная команда'), findsOneWidget);
      expect(destinations, hasLength(menuActions - 1));
    }

    await choose();
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(destinations, [null]);

    await choose();
    await tester.tap(find.widgetWithText(FilledButton, 'Продолжить'));
    await tester.pumpAndSettle();
    expect(destinations.last?.chatId, _chatId);
    expect(destinations.last?.title, 'Проектная команда');
    expect(sourceTaps, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'a blank spot beside a real message menu dismisses on the first tap',
      (tester) async {
    portrait(tester);
    await initSupabase(tester);
    final scroll = ScrollController();
    final search = ChatSearchController();
    addTearDown(scroll.dispose);
    addTearDown(search.dispose);
    final actions = <String>[];
    var underlyingTaps = 0;
    const body = 'Рядовое сообщение';
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => underlyingTaps++,
            child: ChatMessageList(
              messages: [
                Message(
                    id: 'example',
                    chatId: 'chat',
                    authorId: 'peer',
                    authorLogin: 'student',
                    authorName: 'Студент',
                    text: body,
                    at: DateTime(2026, 11, 25)),
              ],
              controller: scroll,
              messageKeys: {},
              search: search,
              currentUserId: 'student',
              selectingMessages: false,
              selectedMessageIds: const {},
              onReply: (_) => actions.add('Ответить'),
              onToggleSelect: null,
              onLongPress: (_, __, ___, ____, _____, ______) {},
              onReplyTap: (_) {},
              onReact: (_, label) => actions.add(label),
              onMenuAction: (_, action) => actions.add(action),
            ),
          ),
        ),
      ),
    );

    Future<void> open() async {
      await tester.longPress(find.text(body));
      await tester.pumpAndSettle();
      expect(find.text('Переслать'), findsOneWidget);
    }

    await open();
    final menuText = tester.getCenter(find.text('Переслать'));
    // The overlay's scroll view extends further than the actual menu panel.
    await tester.tapAt(Offset(320, menuText.dy));
    await tester.pumpAndSettle();
    expect(find.text('Переслать'), findsNothing);
    expect(underlyingTaps, 0);
    expect(actions, isEmpty);

    await open();
    await tester.tap(find.text('Переслать'));
    await tester.pumpAndSettle();
    expect(actions, ['Переслать']);
    expect(find.text('Переслать'), findsNothing);
    expect(underlyingTaps, 0);
  });
}
