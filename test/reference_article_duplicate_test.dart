import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('repeated introductory paragraph appears once', (tester) async {
    const article = ManagedReferenceArticle(
      id: 'reference',
      title: 'Справка',
      schemaVersion: 1,
      origin: ContentOrigin.demo,
      sortOrder: 0,
      categoryId: 'category',
      categoryTitle: 'Раздел',
      payload: ReferenceArticlePayload(
        iconKey: 'help',
        shortText: 'Краткое описание',
        blocks: [
          ReferenceTextBlock(text: 'Краткое описание'),
          ReferenceTextBlock(text: 'Полезные подробности'),
        ],
      ),
    );
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: StudentReferenceArticleDetail(article: article)),
    ));
    expect(find.text('Краткое описание'), findsOneWidget);
    expect(find.text('Полезные подробности'), findsOneWidget);
  });
}
