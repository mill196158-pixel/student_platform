import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

/// Minimal valid 1x1 PNG.
final Uint8List kTestPngBytes = Uint8List.fromList(<int>[
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
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
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

const _title = 'Promo title visible';
const _variants = <String>[
  'gradient_text',
  'image_full',
  'image_overlay',
  'image_top_text',
  'compact_icon',
  'accent_info',
  'no_image',
];

HomePromoPayload _payloadForVariant(String variant) {
  return HomePromoPayload.demoStuckWithAssignment.copyWith(
    title: _title,
    cardVariant: variant,
    gradientColors: const [Color(0xFFFFFBFF), Color(0xFFF3EEF9)],
  );
}

Future<void> pumpPromoInUnboundedScroll(
  WidgetTester tester, {
  required HomePromoPayload payload,
  Uint8List? imageBytes,
  bool imageLoading = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: studentPlatformLightTheme(),
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: StudentHomePromoCard(
                payload: payload,
                imageBytes: imageBytes,
                imageLoading: imageLoading,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (imageLoading) {
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
}

double promoCardHeight(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(
    find.byType(StudentHomePromoCard),
  );
  return box.size.height;
}

void main() {
  group('all variants in unbounded scroll', () {
    for (final variant in _variants) {
      testWidgets('$variant keeps title visible', (tester) async {
        await pumpPromoInUnboundedScroll(
          tester,
          payload: _payloadForVariant(variant),
          imageBytes:
              contentCardVariantUsesImage(variant) ? kTestPngBytes : null,
        );
        expect(find.text(_title), findsOneWidget);
        expect(promoCardHeight(tester), greaterThan(8));
      });
    }
  });

  group('image bleed geometry', () {
    for (final variant in ['image_full', 'image_overlay', 'image_top_text']) {
      group(variant, () {
        testWidgets('ready with png has non-zero height and Image', (
          tester,
        ) async {
          await pumpPromoInUnboundedScroll(
            tester,
            payload: _payloadForVariant(variant),
            imageBytes: kTestPngBytes,
          );
          expect(find.byType(Image), findsWidgets);
          expect(promoCardHeight(tester), greaterThan(40));
          expect(find.text(_title), findsOneWidget);
        });

        testWidgets('loading keeps non-zero height', (tester) async {
          await pumpPromoInUnboundedScroll(
            tester,
            payload: _payloadForVariant(variant),
            imageLoading: true,
          );
          expect(promoCardHeight(tester), greaterThan(40));
          expect(find.text(_title), findsOneWidget);
        });

        testWidgets('missing keeps non-zero height', (tester) async {
          await pumpPromoInUnboundedScroll(
            tester,
            payload: _payloadForVariant(variant),
          );
          expect(promoCardHeight(tester), greaterThan(40));
          expect(find.text(_title), findsOneWidget);
        });
      });
    }

    testWidgets('image_overlay shows subtitle when ready', (tester) async {
      await pumpPromoInUnboundedScroll(
        tester,
        payload: _payloadForVariant('image_overlay'),
        imageBytes: kTestPngBytes,
      );
      expect(
        find.text(HomePromoPayload.demoStuckWithAssignment.subtitle),
        findsOneWidget,
      );
    });

    testWidgets('image_full and image_overlay use bleed height 180', (
      tester,
    ) async {
      for (final variant in ['image_full', 'image_overlay']) {
        await pumpPromoInUnboundedScroll(
          tester,
          payload: _payloadForVariant(variant),
          imageBytes: kTestPngBytes,
        );
        expect(
          promoCardHeight(tester),
          greaterThanOrEqualTo(kHomePromoImageBleedHeight - 1),
        );
      }
    });
  });

  group('HomePromoPayload v2 image fields', () {
    test('tryParse accepts overlay focal and image_fit', () {
      final parsed = HomePromoPayload.tryParse({
        'title': 'T',
        'subtitle': 'S',
        'icon_key': 'help',
        'cta_label': 'Go',
        'gradient_colors': ['#7367F0', '#B784F7'],
        'dismissible': false,
        'overlay_opacity': 0.3,
        'focal_x': 0.2,
        'focal_y': 0.8,
        'image_fit': 'contain',
      });
      expect(parsed, isNotNull);
      expect(parsed!.overlayOpacity, 0.3);
      expect(parsed.focalX, 0.2);
      expect(parsed.focalY, 0.8);
      expect(parsed.imageFit, 'contain');
      expect(parsed.toWireJson()['overlay_opacity'], 0.3);
    });

    test('tryParse rejects invalid overlay_opacity', () {
      expect(
        HomePromoPayload.tryParse({
          'title': 'T',
          'subtitle': 'S',
          'icon_key': 'help',
          'cta_label': 'Go',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': false,
          'overlay_opacity': 1.5,
        }),
        isNull,
      );
    });

    test('tryParse rejects invalid image_fit', () {
      expect(
        HomePromoPayload.tryParse({
          'title': 'T',
          'subtitle': 'S',
          'icon_key': 'help',
          'cta_label': 'Go',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': false,
          'image_fit': 'stretch',
        }),
        isNull,
      );
    });
  });
}
