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

  test('ManagedContentCard.tryParseHomePromo ignores foreign templates', () {
    expect(
      ManagedContentCard.tryParseHomePromo({
        'id': 'x',
        'template_key': 'reference_article_v1',
        'payload': {'title': 'a'},
      }),
      isNull,
    );
  });

  testWidgets('StudentHomePromoCard renders typed fields without raw JSON', (
    tester,
  ) async {
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
