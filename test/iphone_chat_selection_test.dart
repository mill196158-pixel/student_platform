import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/themes/themes.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/messages/chat_message_list.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/scroll_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/search/chat_search_controller.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/selection_bars.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cold_start_session_test.dart' show sessionFixture;

const _ownId = 'test-user';
const _lastOwn = 'Перепроверю единицы и пришлю расчёт вечером.';
const _peer = 'Уточни, пожалуйста, расчётный пролёт и тип опор.';
const _long =
    'Приложил схему с опорами. Для проверки прогиба берём рабочее сочетание нагрузок и сверяем единицы измерения перед подстановкой в формулу.';

Message _message(int number, String sender, String text) => Message(
      id: 'message-$number',
      chatId: 'materials',
      authorId: sender == 'me' ? _ownId : sender,
      authorLogin: sender,
      authorName: sender == 'me' ? 'Студент' : 'Полина',
      text: text,
      at: DateTime(2026, 11, 27, 11, number),
    );

Future<void> _capture(GlobalKey key, String name) async {
  final directory = Platform.environment['STUDENT_SELECTION_CAPTURES'];
  if (directory == null) return;
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

class _ChatFixture extends StatefulWidget {
  const _ChatFixture({
    required this.messages,
    required this.scrollController,
    required this.search,
    required this.actions,
    this.normalBottomExtra = 0,
  });

  final List<Message> messages;
  final ScrollController scrollController;
  final ChatSearchController search;
  final List<Object> actions;
  final double normalBottomExtra;

  @override
  State<_ChatFixture> createState() => _ChatFixtureState();
}

class _ChatFixtureState extends State<_ChatFixture> {
  final _selected = <String>{};
  final _messageKeys = <String, GlobalKey>{};
  late final _chatScroll =
      ChatScrollController(widget.scrollController, _messageKeys);

  void _toggle(String id) {
    void change() => setState(() {
          if (!_selected.remove(id)) _selected.add(id);
        });
    if (_selected.isEmpty ||
        (_selected.length == 1 && _selected.contains(id))) {
      _chatScroll.keepVisibleMessage(change);
    } else {
      change();
    }
  }

  @override
  Widget build(BuildContext context) {
    final inSelection = _selected.isNotEmpty;
    final selectedMessages =
        widget.messages.where((message) => _selected.contains(message.id));
    return Scaffold(
      appBar: inSelection
          ? TopSelectionBar(
              count: _selected.length,
              onClose: () => _chatScroll.keepVisibleMessage(
                () => setState(_selected.clear),
              ),
            )
          : AppBar(title: const Text('Сопротивление материалов')),
      body: Column(
        children: [
          Expanded(
            child: ChatMessageList(
              messages: widget.messages,
              controller: widget.scrollController,
              messageKeys: _messageKeys,
              search: widget.search,
              currentUserId: _ownId,
              selectingMessages: inSelection,
              selectedMessageIds: _selected,
              onReply: (message) => widget.actions.add(('Reply', message.id)),
              onToggleSelect: _toggle,
              onLongPress: (_, __, ___, ____, _____, ______) {},
              onReplyTap: (_) {},
              onReact: (_, id) => widget.actions.add(('React', id)),
              canDeleteMessage: (message) => message.isMine(_ownId),
              onMenuAction: (message, action) {
                if (action == 'Выбрать') {
                  _toggle(message.id);
                }
              },
            ),
          ),
          if (inSelection)
            BottomSelectionBar(
              onCopy: () => widget.actions.add(('Copy', _selected.length)),
              onForward: () =>
                  widget.actions.add(('Forward', _selected.length)),
              onDelete:
                  selectedMessages.any((message) => message.isMine(_ownId))
                      ? () => widget.actions.add(('Delete', _selected.length))
                      : null,
              onUnavailable: widget.actions.add,
            )
          else
            SizedBox(
              height:
                  Composer.restingHeightOf(context) + widget.normalBottomExtra,
            ),
        ],
      ),
    );
  }
}

Future<void> _selectThroughMenu(WidgetTester tester, String text) async {
  await tester.longPress(find.text(text));
  await _tapSelectionInMenu(tester);
}

Future<void> _tapSelectionInMenu(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final choose = find.text('Выбрать');
  await tester.ensureVisible(choose);
  await tester.pumpAndSettle();
  await tester.tapAt(tester.getCenter(choose));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initializeDateFormatting('ru');
    final textFont = FontLoader('packages/student_ui/WorkspaceSans')
      ..addFont(rootBundle
          .load('packages/student_ui/assets/fonts/NotoSans-Regular.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([textFont.load(), icons.load()]);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.app_links/events'),
      (_) async => null,
    );
    await Supabase.initialize(
      url: 'https://selection.example.invalid',
      publishableKey: 'fixture',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
    await Supabase.instance.client.auth.setInitialSession(
      jsonEncode(
          sessionFixture(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600)),
    );
  });

  tearDownAll(() async {
    await Supabase.instance.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/events'), null);
  });

  for (final (label, width, brightness, scale) in [
    ('light', 390.0, Brightness.light, 1.0),
    ('dark-compact', 320.0, Brightness.dark, 1.4),
  ]) {
    testWidgets('chat selection capture $label', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      final scroll = ScrollController();
      final search = ChatSearchController();
      final actions = <Object>[];
      final boundary = GlobalKey();
      final theme = brightness == Brightness.light
          ? AppTheme.light().data
          : AppTheme.dark().data;
      addTearDown(scroll.dispose);
      addTearDown(search.dispose);
      await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.copyWith(
            platform: TargetPlatform.iOS,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: _ChatFixture(
            messages: [
              _message(0, 'peer', 'Утром уточнили данные по заданию.'),
              _message(1, 'me', _long),
              _message(2, 'peer', 'Забрала замечания по схеме. Спасибо!'),
              _message(3, 'peer', _peer),
              _message(4, 'me', _lastOwn),
              _message(5, 'peer', 'Хорошо, тогда проверим вместе перед парой.'),
            ],
            scrollController: scroll,
            search: search,
            actions: actions,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final normalRects = {
        for (final text in [_lastOwn, _peer, _long])
          text: tester.getRect(find.text(text)),
      };
      await _selectThroughMenu(tester, _peer);
      expect(find.text('Выбрано 1'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.getRect(find.text(_peer)), normalRects[_peer]);
      expect(tester.getRect(find.text(_long)), normalRects[_long]);

      await tester.tap(find.text('Удалить'));
      expect(
          actions, ['Удалить можно только свои сообщения не старше 12 часов']);
      await tester.pumpAndSettle();

      await tester.tapAt(tester.getCenter(find.text(_lastOwn)));
      await tester.pumpAndSettle();
      expect(find.text('Выбрано 2'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNWidgets(2));
      Rect checkFor(String id) => tester.getRect(find.descendant(
            of: find.byKey(ValueKey('message-message-$id')),
            matching: find.byIcon(Icons.check_rounded),
          ));
      expect(checkFor('4').right, lessThan(normalRects[_lastOwn]!.left - 14));
      expect(checkFor('3').left, greaterThan(normalRects[_peer]!.right + 14));
      for (final entry in normalRects.entries) {
        expect(tester.getRect(find.text(entry.key)), entry.value);
      }
      await tester.dragFrom(
          tester.getCenter(find.text(_peer)), const Offset(84, 0));
      await tester.pumpAndSettle();
      expect(actions, hasLength(1));
      expect(find.text('Выбрано 2'), findsOneWidget);

      final actionBarRect = tester.getRect(find.byType(BottomSelectionBar));
      for (final caption in ['Копировать', 'Переслать', 'Удалить']) {
        final labelRect = tester.getRect(find.text(caption));
        expect(actionBarRect.contains(labelRect.center), isTrue);
        expect(labelRect.height, lessThan(22));
        await tester.tap(find.text(caption));
      }
      expect(actions.skip(1), [('Copy', 2), ('Forward', 2), ('Delete', 2)]);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => _capture(boundary, 'selection-$label'));

      await tester.tapAt(tester.getCenter(find.text(_lastOwn)));
      await tester.pumpAndSettle();
      expect(find.text('Выбрано 1'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.text(_peer)));
      await tester.pumpAndSettle();
      expect(find.byType(TopSelectionBar), findsNothing);
      expect(find.byType(BottomSelectionBar), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(tester.getRect(find.text(_peer)), normalRects[_peer]);
    });
  }

  testWidgets('zero eligible messages explains unavailable actions',
      (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light().data,
      home: Scaffold(
        appBar: TopSelectionBar(
          includeTopInset: false,
          count: 0,
          onClose: () => actions.add('close'),
        ),
        body: Column(children: [
          const Spacer(),
          BottomSelectionBar(
            onForward: null,
            onDelete: null,
            onUnavailable: actions.add,
          ),
        ]),
      ),
    ));
    expect(find.text('Выбрано 0'), findsOneWidget);
    await tester.tap(find.text('Копировать'));
    await tester.tap(find.text('Переслать'));
    await tester.tap(find.text('Удалить'));
    await tester.tap(find.byTooltip('Назад'));
    expect(actions, [
      'Нечего копировать',
      'Выберите сообщения',
      'Удалить можно только свои сообщения не старше 12 часов',
      'close',
    ]);
  });

  testWidgets('full-width forwarded card has room for its selection check',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 780);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final scroll = ScrollController();
    final search = ChatSearchController();
    addTearDown(scroll.dispose);
    addTearDown(search.dispose);
    final messages = [
      _message(1, 'peer', '').copyWith(
        type: MessageType.forward,
        forward: ForwardPayloadModel(
          fromChatId: 'class',
          fromChatTitle: 'Сопромат',
          items: [
            ForwardItemModel(
              id: 'original-message',
              authorId: 'peer',
              authorName: 'Полина',
              at: DateTime(2026, 11, 27, 10),
              text: _long,
            ),
          ],
        ),
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light().data,
      home: _ChatFixture(
        messages: messages,
        actions: [],
        scrollController: scroll,
        search: search,
      ),
    ));
    await tester.pumpAndSettle();
    final content = find.text(_long);
    final originalRect = tester.getRect(content);
    await _selectThroughMenu(tester, _long);
    expect(find.text('Выбрано 1'), findsOneWidget);
    expect(tester.getRect(content), originalRect);
    final checkRect = tester.getRect(find.byIcon(Icons.check_rounded));
    final titleRect = tester.getRect(find.text('Переслано из: Сопромат'));
    expect(checkRect.right, lessThan(titleRect.left - 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'visible message stays put when selection changes viewport height',
      (tester) async {
    final scroll = ScrollController();
    final search = ChatSearchController();
    addTearDown(scroll.dispose);
    addTearDown(search.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light().data,
      home: _ChatFixture(
        messages: [
          for (var i = 0; i < 30; i++)
            _message(i, i.isEven ? 'me' : 'peer', 'Проверка расчёта $i'),
        ],
        actions: [],
        scrollController: scroll,
        search: search,
        normalBottomExtra: 35,
      ),
    ));
    await tester.pumpAndSettle();
    scroll.jumpTo(309);
    await tester.pumpAndSettle();
    final message = find.text('Проверка расчёта 20').hitTestable();
    expect(message, findsOneWidget);
    final originalRect = tester.getRect(message);
    await _selectThroughMenu(tester, 'Проверка расчёта 20');
    expect(find.text('Выбрано 1'), findsOneWidget);
    expect(tester.getRect(find.text('Проверка расчёта 20')), originalRect);
    expect(scroll.offset, closeTo(274, 1));
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(tester.getRect(message), originalRect);
    expect(scroll.offset, closeTo(309, 1));
  });
  testWidgets('selection anchors a message taller than the visible history',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final scroll = ScrollController();
    final search = ChatSearchController();
    addTearDown(scroll.dispose);
    addTearDown(search.dispose);
    final text = List.filled(10, _long).join('\n');
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light().data,
      home: _ChatFixture(
        messages: [_message(0, 'peer', text)],
        actions: [],
        scrollController: scroll,
        search: search,
        normalBottomExtra: 36,
      ),
    ));
    await tester.pumpAndSettle();
    scroll.jumpTo(120);
    await tester.pumpAndSettle();
    final message = find.text(text);
    final originalRect = tester.getRect(message);
    final viewport = tester.getRect(find.byType(ListView));
    expect(originalRect.top, lessThan(viewport.top));
    expect(originalRect.bottom, greaterThan(viewport.bottom));

    await tester.longPressAt(viewport.center);
    await _tapSelectionInMenu(tester);
    expect(find.text('Выбрано 1'), findsOneWidget);
    expect(tester.getRect(message), originalRect);
    expect(scroll.offset, closeTo(84, 1));
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(tester.getRect(message), originalRect);
    expect(scroll.offset, closeTo(120, 1));
  });
}
