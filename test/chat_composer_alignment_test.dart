import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/chats/core/chat_messages_load_state.dart';
import 'package:student_platform/src/ui/chats/core/dm_composer_bar.dart';
import 'package:student_platform/src/ui/chats/core/i_chat_service.dart';
import 'package:student_platform/src/ui/chats/core/unified_chat_screen.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer/chat_composer_bar.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _PrivateChat extends Fake implements IChatService {
  @override
  ChatMode get mode => ChatMode.dm;
  @override
  bool get supportsAssignments => false;
  @override
  bool get supportsNotes => false;
  @override
  String get currentUserId => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  @override
  String get chatId => '11111111-1111-4111-8111-111111111111';
  @override
  List<Message> get currentMessages => const [];
  @override
  ChatMessagesViewState get messagesViewState => const ChatMessagesViewState(
        phase: ChatMessagesLoadPhase.ready,
        messages: [],
        hasSnapshot: true,
      );
  @override
  Future<String> ensureChatId() async => chatId;
  @override
  Future<Map<String, dynamic>> getUnreadMeta() async => {};
  @override
  Stream<ChatMessagesViewState> watchMessagesState() =>
      Stream.value(messagesViewState);
  @override
  Stream<List<Message>> watchMessages() => Stream.value(currentMessages);
}

Future<void> _capture(GlobalKey key, String name) async {
  final path = Platform.environment['STUDENT_CHAT_ALIGNMENT_CAPTURE_DIR'];
  if (path == null) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = boundary.toImageSync();
  try {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('$path/$name.png').writeAsBytes(
      png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = FontLoader('packages/student_ui/WorkspaceSans')
      ..addFont(rootBundle.load(
        'packages/student_ui/assets/fonts/NotoSans-Regular.ttf',
      ));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([font.load(), icons.load()]);
  });

  testWidgets('private header preserves navigation and actions at 320 px',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);

    SharedPreferences.setMockInitialValues({});
    const links = MethodChannel('com.llfbandit.app_links/events');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(links, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(links, null));
    final service = _PrivateChat();
    await tester.runAsync(() async {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: 'test',
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async => http.Response('[]', 200,
            request: request, headers: {'content-type': 'application/json'})),
      );
      String base64Part(Map<String, Object> part) =>
          base64Url.encode(utf8.encode(jsonEncode(part))).replaceAll('=', '');
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final issuer = '${SupabaseConfig.url}/auth/v1';
      final payload = base64Part({
        'iss': issuer,
        'aud': 'authenticated',
        'role': 'authenticated',
        'sub': service.currentUserId,
        'session_id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        'iat': now,
        'exp': now + 3600,
      });
      await Supabase.instance.client.auth.setInitialSession(jsonEncode({
        'access_token': '${base64Part({'alg': 'none'})}.$payload.synthetic',
        'refresh_token': 'test',
        'token_type': 'bearer',
        'expires_at': now + 3600,
        'user': {
          'id': service.currentUserId,
          'aud': 'authenticated',
          'app_metadata': {},
          'user_metadata': {},
          'created_at': '2026-01-01T00:00:00Z',
        },
      }));
    });
    addTearDown(() => tester.runAsync(Supabase.instance.dispose));

    final boundary = GlobalKey();
    var openedPeer = 0;
    await tester.pumpWidget(AuthSessionScopeHost(
        child: MaterialApp(
      theme: ProductTheme.build(brightness: Brightness.dark)
          .copyWith(platform: TargetPlatform.iOS),
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RepaintBoundary(
                  key: boundary,
                  child: UnifiedChatScreen(
                    service: service,
                    title: 'Захар Утков',
                    onOpenPeer: () => openedPeer++,
                  ),
                ),
              )),
              child: const Text('Открыть чат'),
            ),
          ),
        );
      }),
    )));
    await tester.tap(find.text('Открыть чат'));
    await tester.pump();
    for (var index = 0;
        index < 50 && find.byType(TextField).hitTestable().evaluate().isEmpty;
        index++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 360));
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    await tester.runAsync(() => _capture(boundary, 'private-full-screen'));
    final bar = find.byType(AppBar);
    final avatar =
        find.descendant(of: bar, matching: find.byType(CircleAvatar));
    final name = find.text('Захар Утков');
    final overflow = find.byIcon(Icons.more_horiz);
    expect(tester.widget<AppBar>(bar).toolbarHeight, 60);
    expect(tester.getSize(avatar), const Size.square(40));
    expect(tester.getRect(avatar).right, lessThan(tester.getRect(name).left));
    expect(tester.getRect(name).right, lessThan(tester.getRect(overflow).left));
    await tester.tap(name);
    expect(openedPeer, 1);
    await tester.tap(overflow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Поиск сообщений'), findsOneWidget);
    await tester.tapAt(const Offset(160, 250));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Открыть чат'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final direct in [false, true]) {
    testWidgets('${direct ? 'private' : 'group'} composer at 320 px',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewInsets);
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final captureKey = GlobalKey();
      final chat = direct ? 'Захар Утков' : 'Надёжность систем водоснабжения';
      final prefix = direct ? 'private' : 'group';
      final brightness = direct ? Brightness.dark : Brightness.light;
      const permissionsMessage = 'Только чтение';
      var sends = 0;
      var attachments = 0;

      Widget fixture({double scale = 1, String? blocked}) {
        final composer = direct
            ? DmComposerBar(
                controller: controller,
                focusNode: focus,
                unavailableLabel: blocked,
                replyTo: null,
                onCloseReply: () {},
                someoneTyping: false,
                typingNames: const [],
                attachedFiles: const [],
                onSend: () => sends++,
                onPickImage: () async {},
                onOpenEmoji: () {},
                onAttachFile: () async => attachments++,
                onRemoveFile: (_) {},
                onAddFile: (_) {},
                onPinText: (_) {},
              )
            : ChatComposerBar(
                controller: controller,
                focusNode: focus,
                unavailableLabel: blocked,
                replyTo: null,
                onCloseReply: () {},
                someoneTyping: false,
                typingNames: const [],
                attachedFiles: const [],
                onSend: () => sends++,
                onPickImage: () async {},
                onOpenEmoji: () {},
                onAttachFile: () async => attachments++,
                onRemoveFile: (_) {},
                onAddFile: (_) {},
                onPinText: (_) {},
                onFind: () async {},
                onPropose: (_, __, ___, ____, _____) async {},
              );
        return MaterialApp(
          theme: ProductTheme.build(brightness: brightness)
              .copyWith(platform: TargetPlatform.iOS),
          home: Builder(builder: (context) {
            return MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(
                key: captureKey,
                child: Scaffold(
                  appBar: AppBar(
                    title: Text(chat,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: composer,
                  ),
                ),
              ),
            );
          }),
        );
      }

      final input = find.byType(TextField);
      final hint = find.byKey(const ValueKey('chat-composer-visible-hint'));
      final nativeHint =
          find.descendant(of: input, matching: find.text('Сообщение'));
      final plus = find.ancestor(
        of: find.byIcon(Icons.add),
        matching: find.byType(InkWell),
      );
      final editor = find.ancestor(
        of: input,
        matching: find.byWidgetPredicate((widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).borderRadius ==
                BorderRadius.circular(24)),
      );
      final send = find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded);
      List<Rect> row() => [
            tester.getRect(plus),
            tester.getRect(editor),
            tester.getRect(send),
          ];
      double hintCenterY() {
        final paragraph = tester.renderObject<RenderParagraph>(hint);
        final text = paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 'Сообщение'.length),
        );
        return paragraph.localToGlobal(text.single.toRect().center).dy;
      }

      await tester.pumpWidget(fixture());
      await tester.pumpAndSettle();
      await tester.runAsync(() => _capture(captureKey, '$prefix-closed'));
      final normal = row();
      final normalHintCenter = hintCenterY();
      expect(tester.widget<TextField>(input).decoration?.hintText, 'Сообщение');
      expect(tester.getTopLeft(hint).dx, tester.getTopLeft(nativeHint).dx);
      final normalHint = tester.getSize(hint).width;
      await tester.tap(find.byTooltip('Прикрепить файл'));
      expect(attachments, 1);
      expect(find.byTooltip('Прикрепить изображение'), findsOneWidget);

      await tester.tap(input);
      tester.view.padding = const FakeViewPadding(top: 44);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpWidget(fixture(scale: 1.6));
      await tester.pumpAndSettle();
      await tester.runAsync(() => _capture(captureKey, '$prefix-keyboard'));
      final keyboard = row();
      final largeHintCenter = hintCenterY();
      expect(tester.getTopLeft(hint).dx, tester.getTopLeft(nativeHint).dx);
      final largeHint = tester.getSize(hint).width;
      final largeHintParagraph = tester.renderObject<RenderParagraph>(hint);
      final largeHintTruncated = largeHintParagraph.didExceedMaxLines;
      expect(focus.hasFocus, isTrue);

      await tester.enterText(input, 'Раз\nДва\nТри');
      await tester.pumpAndSettle();
      final multiline = row();
      expect(hint, findsNothing);
      final editable = tester
          .state<EditableTextState>(find.byType(EditableText))
          .renderEditable;
      final firstCaret = editable
          .getLocalRectForCaret(const TextPosition(offset: 0))
          .shift(editable.localToGlobal(Offset.zero));
      final lastCaret = editable
          .getLocalRectForCaret(TextPosition(offset: controller.text.length))
          .shift(editable.localToGlobal(Offset.zero));
      expect(find.byTooltip('Прикрепить файл').hitTestable(), findsOneWidget);
      await tester.tap(send);
      expect(sends, 1);

      controller.clear();
      focus.unfocus();
      await tester.pumpAndSettle();
      final openHeight = tester.getSize(find.byType(Composer)).height;
      await tester.pumpWidget(fixture(scale: 1.6, blocked: permissionsMessage));
      await tester.pumpAndSettle();
      expect(find.text(permissionsMessage), findsOneWidget);
      expect(input.hitTestable(), findsNothing);
      expect(send.hitTestable(), findsNothing);
      expect(tester.getSize(find.byType(Composer)).height, openHeight);
      expect(tester.takeException(), isNull);

      for (final controls in [normal, keyboard]) {
        expect(controls.map((rect) => rect.height), everyElement(48));
        expect(controls.map((rect) => rect.center.dy).toSet(), hasLength(1));
      }
      expect(normalHintCenter, closeTo(normal.first.center.dy, .5));
      expect(largeHintCenter, closeTo(keyboard.first.center.dy, .5));
      expect(multiline[1].height, greaterThan(48));
      expect(multiline.map((rect) => rect.bottom).toSet(), hasLength(1));
      expect(firstCaret.top, greaterThanOrEqualTo(multiline[1].top));
      expect(lastCaret.top, greaterThan(firstCaret.top));
      expect(lastCaret.bottom, lessThanOrEqualTo(multiline[1].bottom));
      expect(largeHint, greaterThanOrEqualTo(normalHint));
      expect(largeHintTruncated, isFalse);
    });
  }
}
