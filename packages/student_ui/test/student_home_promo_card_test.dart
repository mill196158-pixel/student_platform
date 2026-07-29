import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

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

  test('ManagedContentCard.tryParseHomePromo enforces schema_version=1', () {
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
}
