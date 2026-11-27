import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/cache_inventory_snapshot.dart';
import 'package:student_platform/src/ui/profile/cache_diagnostics_screen.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final captureDirectory = Platform.environment['STUDENT_APP_DATA_CAPTURES'];
  final captureBefore = Platform.environment['STUDENT_APP_DATA_BEFORE'] == '1';

  if (captureDirectory != null) {
    setUpAll(() async {
      final text = FontLoader('packages/student_ui/WorkspaceSans')
        ..addFont(rootBundle
            .load('packages/student_ui/assets/fonts/NotoSans-Regular.ttf'));
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await Future.wait([text.load(), icons.load()]);
    });
  }

  for (final (name, brightness, width, scale, withBack) in [
    ('narrow-large-light', Brightness.light, 320.0, 1.6, true),
    ('narrow-large-dark', Brightness.dark, 320.0, 1.6, true),
    ('narrow-extra-large-dark', Brightness.dark, 320.0, 2.0, true),
    ('regular-light', Brightness.light, 390.0, 1.0, false),
  ]) {
    testWidgets('App data title and action stay usable $name', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 720);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      final boundary = GlobalKey();
      final data = CacheDiagnosticsScreen(
        measure: () async => InventorySnapshot(
          startedAt: DateTime(2026, 11, 27),
          finishedAt: DateTime(2026, 11, 27),
          observations: const [
            InventoryObservation(
                'public_news_blobs_v2', InventoryClass.optional, 12400000),
            InventoryObservation('offline_chat_ordinary_v1.db',
                InventoryClass.protectedOrMixed, 5000000),
          ],
        ),
      );
      await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ProductTheme.build(brightness: brightness)
              .copyWith(platform: TargetPlatform.iOS),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: withBack
              ? Builder(
                  builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(builder: (_) => data)),
                          child: const Text('Открыть'),
                        ),
                      ))
              : data,
        ),
      ));
      if (withBack) await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (captureDirectory != null) {
        final surface = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await surface.toImage(pixelRatio: 2);
          try {
            final bytes =
                (await image.toByteData(format: ui.ImageByteFormat.png))!;
            final directory =
                await Directory(captureDirectory).create(recursive: true);
            final mark = captureBefore ? 'before' : 'after';
            await File('${directory.path}/app-data-$mark-$name.png')
                .writeAsBytes(bytes.buffer
                    .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
          } finally {
            image.dispose();
          }
        });
      }
      if (captureBefore) return;

      final title = find.text('Данные приложения');
      expect(tester.getCenter(title).dx, closeTo(width / 2, 0.5));
      expect(tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
          isFalse);
      for (final removed in [
        'Дополнительно',
        'Обновить',
        'Лимит кэша',
        'Место на устройстве'
      ]) {
        expect(find.text(removed), findsNothing);
      }
      final clear = find.text('Очистить кэш');
      if (scale > 1.6) {
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
      }
      expect(clear.hitTestable(), findsOneWidget);
      expect(find.text('12.4 МБ'), findsOneWidget);
      await tester.tap(clear);
      await tester.pumpAndSettle();
      expect(find.text('Очистить кэш?'), findsOneWidget);
      expect(find.text('Очистить'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
