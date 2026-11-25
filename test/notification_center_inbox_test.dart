import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/notifications/notification_center_sheet.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> _event(String id, String type, String title, String body,
        {Map<String, dynamic> data = const {}, bool read = false}) =>
    {
      'id': id,
      'event_type': type,
      'title': title,
      'body': body,
      'data': data,
      'created_at': '2026-11-24T10:2${id}:${id}0',
      'read_at': read ? '2026-11-24T11:00:00' : null,
    };

Future<void> _loadFonts() async {
  final font = FontLoader('packages/student_ui/WorkspaceSans')
    ..addFont(rootBundle
        .load('packages/student_ui/assets/fonts/NotoSans-Regular.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([font.load(), icons.load()]);
}

Future<void> _saveSheet(
    WidgetTester tester, GlobalKey boundaryKey, String name) async {
  final output = Platform.environment['NOTIFICATION_RENDER_DIR'];
  if (output == null || output.isEmpty) return;
  final sheet = tester.getRect(find.byType(BottomSheet));
  final boundary =
      boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final frame = await boundary.toImage(pixelRatio: 2);
    final recorder = ui.PictureRecorder();
    final width = (sheet.width * 2).round(),
        height = (sheet.height * 2).round();
    Canvas(recorder).drawImageRect(
        frame,
        Rect.fromLTWH(
            sheet.left * 2, sheet.top * 2, sheet.width * 2, sheet.height * 2),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint());
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    frame.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await initializeDateFormatting('ru_RU');
    await _loadFonts();
  });
  for (final (name, width, scale, brightness) in [
    ('notifications-light', 390.0, 1.0, Brightness.light),
    ('notifications-dark-compact', 320.0, 1.4, Brightness.dark),
  ]) {
    testWidgets('notification inbox: $name', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final items = [
        _event(
            '5', 'dm_message', 'Анастасия Соколова', 'Пришлёшь чертёж до пары?',
            data: {'chat_id': 'chat-one'}),
        _event('4', 'dm_message', 'Анастасия Соколова', 'Проверила размеры.',
            data: {'chat_id': 'chat-one'}, read: true),
        _event('3', 'team_message', 'Группа АС-21',
            'Преподаватель уже в аудитории.',
            data: {'chat_id': 'chat-two'}),
        _event('2', 'assignment', 'Сопротивление материалов',
            'Расчёт балки нужно сдать к пятнице.',
            data: {'assignment_id': 'work'}),
        _event('1', 'schedule_change', 'Перенос занятия',
            'Практикум пройдёт в аудитории 308.',
            read: true),
      ];
      final calls = <String>[];
      const channel = MethodChannel('com.llfbandit.app_links/events');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await tester.runAsync(() => Supabase.initialize(
          url: 'https://example.invalid',
          publishableKey: 'test',
          authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false, detectSessionInUri: false),
          httpClient: MockClient((request) async {
            final rpc = request.url.pathSegments.last;
            calls.add(rpc);
            dynamic result;
            switch (rpc) {
              case 'get_my_app_notifications':
                result = items;
              case 'mark_all_notifications_read':
                for (final item in items) {
                  item['read_at'] = '2026-11-24T12:00:00';
                }
              case 'hide_notification_for_me':
                final id = jsonDecode(request.body)['p_notification_id'];
                items.removeWhere((item) => item['id'] == id);
              case 'mark_notification_read':
                final id = jsonDecode(request.body)['p_notification_id'];
                expect(id, '2');
              default:
                fail('Unexpected API call: $rpc');
            }
            return http.Response(jsonEncode(result), 200,
                headers: {'content-type': 'application/json; charset=utf-8'},
                request: request);
          })));
      try {
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              theme: ProductTheme.build(brightness: brightness),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: Scaffold(
                  body: Builder(
                      builder: (context) => Center(
                              child: TextButton(
                            onPressed: () =>
                                showNotificationCenterSheet(context),
                            child: const Text('Открыть'),
                          )))),
            )));
        final openSheet = find.text('Открыть');
        await tester.tap(openSheet);
        await tester.pumpAndSettle();
        expect(find.text('Группа АС-21'), findsNothing);
        expect(find.text('История (2)'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _saveSheet(tester, boundaryKey, name);
        await tester.tap(find.text('Ещё 1'));
        await tester.pumpAndSettle();
        expect(find.text('Группа АС-21'), findsOneWidget);
        await tester.tap(find.text('История (2)'));
        await tester.pumpAndSettle();
        expect(find.text('Проверила размеры.'), findsOneWidget);
        await tester.longPress(find.text('Анастасия Соколова').first);
        await tester.pumpAndSettle();
        expect(calls, contains('hide_notification_for_me'));
        // A single assignment opens directly and marks only its own record.
        final assignment = find.text('Сопротивление материалов');
        await tester.ensureVisible(assignment);
        await tester.tap(assignment);
        await tester.pumpAndSettle();
        expect(calls, contains('mark_notification_read'));
        expect(find.byType(BottomSheet), findsNothing);
        await tester.tap(openSheet);
        await tester.pumpAndSettle();
        final readAll = width < 360
            ? find.byTooltip('Прочитать все')
            : find.text('Прочитать все');
        await tester.tap(readAll);
        await tester.pumpAndSettle();
        expect(calls, contains('mark_all_notifications_read'));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => Supabase.instance.dispose());
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
  }
}
