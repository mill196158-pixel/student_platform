import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

/// Minimal valid 1x1 PNG.
final Uint8List _pngBytes = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x00,
  0x03,
  0x00,
  0x01,
  0x00,
  0x05,
  0xFE,
  0xD4,
  0xEF,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

StudentHomeNews _news({
  required StudentHomeNewsVariant variant,
  Uint8List? imageBytes,
  String title = 'Заголовок новости',
  String subtitle = 'Подзаголовок',
}) {
  return StudentHomeNews(
    id: 'news-${variant.name}',
    title: title,
    subtitle: subtitle,
    body: subtitle,
    icon: Icons.auto_awesome_rounded,
    gradientColors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
    variant: variant,
    imageBytes: imageBytes,
    overlayDarken: 0.5,
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
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('gradientText shows title and subtitle', (tester) async {
    await _pumpCard(
      tester,
      _news(variant: StudentHomeNewsVariant.gradientText),
    );

    expect(find.text('Заголовок новости'), findsOneWidget);
    expect(find.text('Подзаголовок'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('imageOnly hides text and shows image', (tester) async {
    await _pumpCard(
      tester,
      _news(
        variant: StudentHomeNewsVariant.imageOnly,
        imageBytes: _pngBytes,
      ),
    );

    expect(find.text('Заголовок новости'), findsNothing);
    expect(find.text('Подзаголовок'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('imageOverlay shows readable text over image', (tester) async {
    await _pumpCard(
      tester,
      _news(
        variant: StudentHomeNewsVariant.imageOverlay,
        imageBytes: _pngBytes,
      ),
    );

    expect(find.text('Заголовок новости'), findsOneWidget);
    expect(find.text('Подзаголовок'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('imageWithText keeps text outside image plane', (tester) async {
    await _pumpCard(
      tester,
      _news(
        variant: StudentHomeNewsVariant.imageWithText,
        imageBytes: _pngBytes,
        title:
            'Очень длинный заголовок новости который не должен ломать карточку',
        subtitle: 'Длинный подзаголовок тоже обрезается аккуратно без overflow',
      ),
    );

    expect(find.textContaining('Очень длинный заголовок'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching variant keeps image and text in model',
      (tester) async {
    var item = _news(
      variant: StudentHomeNewsVariant.imageOverlay,
      imageBytes: _pngBytes,
      title: 'Сохранённый заголовок',
      subtitle: 'Сохранённый подзаголовок',
    );

    await _pumpCard(tester, item);
    expect(find.text('Сохранённый заголовок'), findsOneWidget);

    item = item.copyWith(variant: StudentHomeNewsVariant.imageOnly);
    await _pumpCard(tester, item);
    expect(find.byType(Image), findsOneWidget);
    expect(item.title, 'Сохранённый заголовок');
    expect(item.subtitle, 'Сохранённый подзаголовок');
    expect(item.imageBytes, isNotNull);

    item = item.copyWith(variant: StudentHomeNewsVariant.imageWithText);
    await _pumpCard(tester, item);
    expect(find.text('Сохранённый заголовок'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(item.imageBytes, same(_pngBytes));
  });
}
