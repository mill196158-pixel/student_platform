import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

/// Solid 64×64 PNG (opaque teal) — large enough to cover card geometry.
Future<Uint8List> _solidPng({
  int width = 64,
  int height = 64,
  Color color = const Color(0xFF2A9D8F),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

StudentHomeNews _news({
  required StudentHomeNewsVariant variant,
  required Uint8List imageBytes,
  Alignment focus = Alignment.center,
}) {
  return StudentHomeNews(
    id: 'geom-${variant.name}',
    title: 'Заголовок',
    subtitle: 'Подзаголовок',
    body: 'Текст новости для большой story.',
    icon: Icons.folder_copy_outlined,
    gradientColors: const [Color(0xFFFF00FF), Color(0xFFFF00FF)],
    variant: variant,
    imageBytes: imageBytes,
    imageFocus: focus,
    overlayDarken: 0.42,
  );
}

Future<void> _pumpCard(WidgetTester tester, StudentHomeNews item) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: studentPlatformLightTheme(),
      home: Scaffold(
        body: Center(child: StudentHomeNewsCard(item: item)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Size _sizeOf(WidgetTester tester, Finder finder) {
  return tester.getSize(finder);
}

void main() {
  late Uint8List png;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    png = await _solidPng();
  });

  testWidgets('imageOverlay image fills the whole card', (tester) async {
    final item = _news(
      variant: StudentHomeNewsVariant.imageOverlay,
      imageBytes: png,
    );
    await _pumpCard(tester, item);

    final card = find.byType(StudentHomeNewsCard);
    final frame = find.descendant(
      of: card,
      matching: find.byType(NewsImageFrame),
    );
    final image = find.descendant(of: frame, matching: find.byType(Image));

    expect(frame, findsOneWidget);
    expect(image, findsOneWidget);
    // Frame fills the card content box (outer size minus 1px border each side).
    final cardSize = _sizeOf(tester, card);
    final frameSize = _sizeOf(tester, frame);
    expect(frameSize.width, closeTo(cardSize.width - 2, 0.5));
    expect(frameSize.height, closeTo(cardSize.height - 2, 0.5));
    expect(_sizeOf(tester, image), frameSize);

    final img = tester.widget<Image>(image);
    expect(img.fit, BoxFit.cover);
    expect(find.byIcon(Icons.folder_copy_outlined), findsNothing);
  });

  testWidgets('imageOnly image fills the whole card', (tester) async {
    final item = _news(
      variant: StudentHomeNewsVariant.imageOnly,
      imageBytes: png,
    );
    await _pumpCard(tester, item);

    final card = find.byType(StudentHomeNewsCard);
    final frame = find.descendant(
      of: card,
      matching: find.byType(NewsImageFrame),
    );
    final image = find.descendant(of: frame, matching: find.byType(Image));

    final cardSize = _sizeOf(tester, card);
    final frameSize = _sizeOf(tester, frame);
    expect(frameSize.width, closeTo(cardSize.width - 2, 0.5));
    expect(frameSize.height, closeTo(cardSize.height - 2, 0.5));
    expect(_sizeOf(tester, image), frameSize);
    expect(tester.widget<Image>(image).fit, BoxFit.cover);
    expect(find.text('Заголовок'), findsNothing);
    expect(find.byIcon(Icons.folder_copy_outlined), findsNothing);
  });

  testWidgets('story hero image fills the media container', (tester) async {
    final item = _news(
      variant: StudentHomeNewsVariant.imageOverlay,
      imageBytes: png,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: studentPlatformLightTheme(),
        home: Scaffold(
          body: StudentNewsStorySheet(news: [item]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final frame = find.byType(NewsImageFrame);
    expect(frame, findsOneWidget);
    final frameSize = _sizeOf(tester, frame);
    expect(frameSize.height, 280);
    expect(frameSize.width, greaterThan(300));

    final image = find.descendant(of: frame, matching: find.byType(Image));
    expect(_sizeOf(tester, image), frameSize);
    expect(tester.widget<Image>(image).fit, BoxFit.cover);
    expect(find.byIcon(Icons.folder_copy_outlined), findsNothing);
    expect(find.text('Заголовок'), findsOneWidget);
  });

  testWidgets('imageWithText keeps a separate text block under media', (
    tester,
  ) async {
    final item = _news(
      variant: StudentHomeNewsVariant.imageWithText,
      imageBytes: png,
    );
    await _pumpCard(tester, item);

    final card = find.byType(StudentHomeNewsCard);
    final frame = find.descendant(
      of: card,
      matching: find.byType(NewsImageFrame),
    );
    final cardSize = _sizeOf(tester, card);
    final frameSize = _sizeOf(tester, frame);

    expect(frameSize.width, closeTo(cardSize.width - 2, 0.5));
    expect(frameSize.height, lessThan(cardSize.height - 2));
    expect(find.text('Заголовок'), findsOneWidget);
    expect(find.text('Подзаголовок'), findsOneWidget);

    final titleTop = tester.getTopLeft(find.text('Заголовок')).dy;
    final frameBottom = tester.getBottomLeft(frame).dy;
    expect(titleTop, greaterThanOrEqualTo(frameBottom - 0.5));
  });

  testWidgets('focal alignment is applied to Image.memory', (tester) async {
    const focus = Alignment(0.35, -0.6);
    final item = _news(
      variant: StudentHomeNewsVariant.imageOnly,
      imageBytes: png,
      focus: focus,
    );
    await _pumpCard(tester, item);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.alignment, focus);
    expect(image.fit, BoxFit.cover);
  });

  testWidgets('no folder icon and magenta stripe under filled overlay', (
    tester,
  ) async {
    final item = _news(
      variant: StudentHomeNewsVariant.imageOverlay,
      imageBytes: png,
    );
    await _pumpCard(tester, item);

    expect(find.byIcon(Icons.folder_copy_outlined), findsNothing);

    final frame = find.byType(NewsImageFrame);
    final image = find.descendant(of: frame, matching: find.byType(Image));
    expect(_sizeOf(tester, image), _sizeOf(tester, frame));
    expect(tester.widget<Image>(image).fit, BoxFit.cover);
  });
}
