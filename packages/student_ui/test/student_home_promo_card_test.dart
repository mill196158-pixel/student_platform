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

HomePromoPayload _promoPayload({String? cardVariant}) {
  return HomePromoPayload.demoStuckWithAssignment.copyWith(
    cardVariant: cardVariant,
    gradientColors: const [Color(0xFFFFFBFF), Color(0xFFF3EEF9)],
  );
}

void main() {
  test('HomePromoPayload.tryParse rejects unknown/incomplete JSON', () {
    expect(HomePromoPayload.tryParse(null), isNull);
    expect(HomePromoPayload.tryParse({'title': 'Only title'}), isNull);
    expect(
      HomePromoPayload.tryParse({
        'title': 'Заголовок',
        'subtitle': 'Текст',
        'icon_key': 'help',
        'cta_label': 'Открыть',
        'gradient_colors': ['#7367F0', '#B784F7'],
        'dismissible': true,
      }),
      isNotNull,
    );
  });

  test('HomePromoPayload.tryParse never throws on malformed types', () {
    expect(
      HomePromoPayload.tryParse({
        'title': 12,
        'subtitle': 'Текст',
        'icon_key': 'help',
        'cta_label': 'Открыть',
        'gradient_colors': ['#7367F0', '#B784F7'],
        'dismissible': true,
      }),
      isNull,
    );
    expect(
      HomePromoPayload.tryParse({
        'title': 'Заголовок',
        'subtitle': 'Текст',
        'icon_key': 'help',
        'cta_label': 'Открыть',
        'gradient_colors': 'not-a-list',
        'dismissible': true,
      }),
      isNull,
    );
    expect(
      HomePromoPayload.tryParse({
        'title': 'Заголовок',
        'subtitle': 'Текст',
        'icon_key': 'help',
        'cta_label': 'Открыть',
        'gradient_colors': ['#7367F0', '#B784F7'],
        'dismissible': 'yes',
      }),
      isNull,
    );
  });

  test('ManagedContentCard.tryParseHomePromo accepts schema_version 1 and 2',
      () {
    expect(
      ManagedContentCard.tryParseHomePromo({
        'id': 'x',
        'template_key': 'home_promo_v1',
        'schema_version': 2,
        'origin': 'admin',
        'payload': {
          'title': 'Заголовок',
          'subtitle': 'Текст',
          'icon_key': 'help',
          'cta_label': 'Открыть',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': true,
          'home_slot': 'after_news',
          'card_variant': 'image_overlay',
        },
      }),
      isA<ManagedContentCard>()
          .having((c) => c.schemaVersion, 'schema', 2)
          .having((c) => c.homePromo.effectiveHomeSlot, 'slot', 'after_news')
          .having((c) => c.homePromo.cardVariant, 'variant', 'image_overlay'),
    );
    expect(
      ManagedContentCard.tryParseHomePromo({
        'id': 'x',
        'template_key': 'home_promo_v1',
        'schema_version': 1,
        'origin': 'admin',
        'payload': {
          'title': 'Заголовок',
          'subtitle': 'Текст',
          'icon_key': 'help',
          'cta_label': 'Открыть',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': true,
        },
      }),
      isA<ManagedContentCard>().having((c) => c.schemaVersion, 'schema', 1),
    );
    expect(
      ManagedContentCard.tryParseHomePromo({
        'id': 'x',
        'template_key': 'home_promo_v1',
        'schema_version': 99,
        'origin': 'admin',
        'payload': {
          'title': 'Заголовок',
          'subtitle': 'Текст',
          'icon_key': 'help',
          'cta_label': 'Открыть',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': true,
        },
      }),
      isNull,
    );
    expect(
      ManagedContentCard.tryParseHomePromo({
        'id': 'x',
        'template_key': 'home_promo_v1',
        'origin': 'admin',
        'payload': {
          'title': 'Заголовок',
          'subtitle': 'Текст',
          'icon_key': 'help',
          'cta_label': 'Открыть',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': true,
        },
      }),
      isNull,
    );
    expect(
      ManagedContentCard.tryParseHomePromo({
        'id': 'x',
        'template_key': 'home_promo_v1',
        'schema_version': 1,
        'origin': 'weird',
        'payload': {
          'title': 'Заголовок',
          'subtitle': 'Текст',
          'icon_key': 'help',
          'cta_label': 'Открыть',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': true,
        },
      }),
      isNull,
    );
    expect(
      ManagedContentCard.tryParseHomePromo({
        'id': 'ok',
        'template_key': 'home_promo_v1',
        'schema_version': 1,
        'origin': 'demo',
        'placement': 'home_promo',
        'payload': {
          'title': 'Заголовок',
          'subtitle': 'Текст',
          'icon_key': 'help',
          'cta_label': 'Открыть',
          'gradient_colors': ['#7367F0', '#B784F7'],
          'dismissible': true,
        },
      }),
      isNotNull,
    );
  });

  testWidgets('StudentHomePromoCard shows dismiss control when dismissible',
      (tester) async {
    var dismissed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentHomePromoCard(
            payload: HomePromoPayload.demoStuckWithAssignment.copyWith(
              dismissible: true,
            ),
            onDismiss: () => dismissed = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Скрыть'));
    expect(dismissed, isTrue);
  });

  testWidgets('StudentHomePromoCard renders typed fields without raw JSON',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: studentPlatformLightTheme(),
        home: Scaffold(
          body: StudentHomePromoCard(
            payload: HomePromoPayload.demoStuckWithAssignment,
            showDemoBadge: true,
            onTap: () => taps++,
          ),
        ),
      ),
    );

    expect(find.text('Застрял с заданием?'), findsOneWidget);
    expect(find.text('Пример'), findsOneWidget);
    expect(find.text('Получить помощь'), findsOneWidget);
    expect(find.textContaining('{'), findsNothing);

    await tester.tap(find.text('Получить помощь'));
    expect(taps, 1);
  });

  testWidgets('image_overlay with bytes shows Image widget', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: studentPlatformLightTheme(),
        home: Scaffold(
          body: StudentHomePromoCard(
            payload: _promoPayload(cardVariant: 'image_overlay'),
            imageBytes: _pngBytes,
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsWidgets);
    expect(find.text('Застрял с заданием?'), findsOneWidget);
  });

  testWidgets('gradient_text shows built-in icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: studentPlatformLightTheme(),
        home: Scaffold(
          body: StudentHomePromoCard(
            payload: _promoPayload(cardVariant: 'gradient_text'),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.psychology_alt_outlined), findsOneWidget);
  });

  testWidgets('variant switch keeps title for overlay', (tester) async {
    const title = 'Overlay title';
    final overlayPayload = _promoPayload(cardVariant: 'image_overlay').copyWith(
      title: title,
    );
    final gradientPayload =
        _promoPayload(cardVariant: 'gradient_text').copyWith(title: title);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentHomePromoCard(
            payload: overlayPayload,
            imageBytes: _pngBytes,
          ),
        ),
      ),
    );
    expect(find.text(title), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentHomePromoCard(payload: gradientPayload),
        ),
      ),
    );
    expect(find.text(title), findsOneWidget);
  });

  test('resolveContentIcon returns none when both empty', () {
    final resolved = resolveContentIcon();
    expect(resolved.isNone, isTrue);
    expect(resolved.iconData, isNull);
  });

  test('effectiveContentCardVariant defaults unknown to gradient_text', () {
    expect(effectiveContentCardVariant(null), 'gradient_text');
    expect(effectiveContentCardVariant('bogus'), 'gradient_text');
    expect(effectiveContentCardVariant('image_overlay'), 'image_overlay');
  });
}
