import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  const sizes = <Size>[
    Size(390, 844),
    Size(430, 932),
  ];
  const scales = <double>[1.0, 1.3];

  ManagedVacancyCard vacancy({
    required String title,
  }) {
    return ManagedVacancyCard(
      id: 'vac-$title',
      origin: ContentOrigin.demo,
      payload: VacancyCardPayload(
        title: title,
        companyName: 'Кампусная лаборатория инноваций',
        summary:
            'Длинное описание вакансии для проверки переноса русских строк на узком экране.',
      ),
    );
  }

  ManagedReferenceArticle article({
    required String title,
    required String category,
  }) {
    return ManagedReferenceArticle(
      id: 'art-$title',
      title: title,
      schemaVersion: 2,
      origin: ContentOrigin.admin,
      sortOrder: 0,
      categoryId: category,
      categoryTitle: category,
      payload: ReferenceArticlePayload(
        iconKey: 'help',
        shortText:
            'Длинное описание статьи справочника для проверки двух строк на мобильном экране.',
        blocks: const [
          ReferenceTextBlock(text: 'Текст статьи.'),
        ],
      ),
    );
  }

  Future<void> pumpDensity(
    WidgetTester tester, {
    required Size size,
    required double textScale,
    required Widget child,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          padding: const EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: MaterialApp(
          theme: studentPlatformLightTheme(),
          home: Scaffold(
            body: child,
            bottomNavigationBar: NavigationBar(
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  label: 'Главная',
                ),
                NavigationDestination(
                  icon: Icon(Icons.info_outline),
                  label: 'Инфо',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in sizes) {
    for (final scale in scales) {
      final tag =
          '${size.width.toInt()}x${size.height.toInt()}@${scale.toStringAsFixed(1)}';

      testWidgets('jobs board densifies without overflow $tag', (tester) async {
        await pumpDensity(
          tester,
          size: size,
          textScale: scale,
          child: StudentJobsBoardView(
            cards: [
              vacancy(
                title:
                    'Стажёр по мобильной разработке Flutter для студенческих проектов',
              ),
            ],
            showProposeActions: true,
            onProposeVacancy: () {},
            onMySubmissions: () {},
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Доска вакансий'), findsOneWidget);
        expect(find.text('Предложить вакансию'), findsOneWidget);
        expect(find.text('Мои заявки'), findsOneWidget);
        expect(find.textContaining('активн'), findsNothing);

        final propose = tester.getSize(find.text('Предложить вакансию'));
        final proposeButton = tester.getSize(
          find.widgetWithText(FilledButton, 'Предложить вакансию'),
        );
        expect(propose.height, lessThanOrEqualTo(proposeButton.height));
        expect(proposeButton.height, greaterThanOrEqualTo(44));
      });

      testWidgets('help browse densifies without overflow $tag',
          (tester) async {
        await pumpDensity(
          tester,
          size: size,
          textScale: scale,
          child: StudentHelpBrowseView(
            articles: [
              article(
                title:
                    'Как восстановить доступ к личному кабинету университета',
                category: 'Доступы и документы',
              ),
              article(
                title: 'Где искать расписание и карту кампуса',
                category: 'Доступы и документы',
              ),
            ],
          ),
        );

        expect(tester.takeException(), isNull);
        expect(find.text('Справочник'), findsOneWidget);
        expect(find.byType(StudentReferenceArticleCard), findsNWidgets(2));
      });
    }
  }
}
