import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  test('fromLegacy maps image variant without bytes to missing', () {
    final state = ContentImageRenderState.fromLegacy(
      usesImageVariant: true,
      bytes: null,
    );
    expect(state.isMissing, isTrue);
    expect(state.isNotApplicable, isFalse);
  });

  test('fromLegacy maps non-image variant to notApplicable', () {
    final state = ContentImageRenderState.fromLegacy(
      usesImageVariant: false,
      bytes: Uint8List.fromList([1]),
    );
    expect(state.isNotApplicable, isTrue);
  });

  test('fromLegacy maps bytes to ready', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final state = ContentImageRenderState.fromLegacy(
      usesImageVariant: true,
      bytes: bytes,
    );
    expect(state.isReady, isTrue);
    expect(state.bytesOrNull, bytes);
  });

  testWidgets('image_overlay keeps layout when image missing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentHomePromoCard(
            payload: const HomePromoPayload(
              title: 'Overlay title',
              subtitle: 'Overlay body',
              iconKey: 'psychology',
              gradientColors: [Color(0xFF111827), Color(0xFF334155)],
              ctaLabel: 'Открыть',
              dismissible: false,
              cardVariant: 'image_overlay',
            ),
            imageState: ContentImageRenderState.missing,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Overlay title'), findsOneWidget);
    expect(find.text('Добавьте изображение'), findsOneWidget);
    // Must not silently become a pure gradient-only card without the plane.
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
  });
}
