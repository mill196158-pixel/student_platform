import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

ManagedReferenceArticle _sampleArticle() {
  return const ManagedReferenceArticle(
    id: 'art-1',
    title: 'Как войти в ЛК',
    schemaVersion: 2,
    origin: ContentOrigin.admin,
    sortOrder: 0,
    categoryId: 'cat-1',
    categoryTitle: 'Доступы',
    payload: ReferenceArticlePayload(
      iconKey: 'help',
      shortText: 'Короткая подсказка по входу',
      blocks: [
        ReferenceTextBlock(text: 'Откройте сайт университета и войдите.'),
      ],
    ),
  );
}

void main() {
  testWidgets('open article shows detail back', (tester) async {
    ManagedReferenceArticle? selected;
    final article = _sampleArticle();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return StudentHelpBrowseView(
                articles: [article],
                selectedArticle: selected,
                onOpenArticle: (value) {
                  setState(() => selected = value);
                },
                onBack: () {
                  setState(() => selected = null);
                },
              );
            },
          ),
        ),
      ),
    );

    expect(find.text('Справочник'), findsOneWidget);
    expect(find.text('Как войти в ЛК'), findsOneWidget);

    await tester.tap(find.text('Как войти в ЛК'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Назад к списку'), findsOneWidget);
    expect(find.text('Откройте сайт университета и войдите.'), findsOneWidget);

    await tester.tap(find.byTooltip('Назад к списку'));
    await tester.pumpAndSettle();

    expect(find.text('Справочник'), findsOneWidget);
    expect(find.byTooltip('Назад к списку'), findsNothing);
  });
}
