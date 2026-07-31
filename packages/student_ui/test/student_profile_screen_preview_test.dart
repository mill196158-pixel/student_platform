import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('shows diary and map study banners', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StudentProfileScreenPreview(
            displayName: 'Анна',
            groupLabel: 'ИСТ-401',
            universityLabel: 'СПБГАСУ',
            feedCards: [
              ManagedProfileFeedCard(
                id: 'feed-1',
                origin: ContentOrigin.demo,
                sortOrder: 0,
                priority: 0,
                payload: ProfileFeedPayload(
                  title: 'О нас',
                  subtitle: 'Команда',
                  ctaLabel: 'Открыть',
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Мой дневник'), findsOneWidget);
    expect(find.textContaining('Карта'), findsOneWidget);
    expect(find.text('Лента'), findsOneWidget);
    expect(find.text('Мои отзывы'), findsOneWidget);
  });

  testWidgets('detailCard shows back chrome', (tester) async {
    var backTapped = false;
    const card = ManagedProfileFeedCard(
      id: 'feed-1',
      origin: ContentOrigin.demo,
      sortOrder: 0,
      priority: 0,
      payload: ProfileFeedPayload(
        title: 'Карточка ленты',
        subtitle: 'Подробности',
        ctaLabel: 'Открыть',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentProfileScreenPreview(
            displayName: 'Анна',
            groupLabel: 'ИСТ-401',
            detailCard: card,
            onBack: () => backTapped = true,
          ),
        ),
      ),
    );

    expect(find.text('Мой дневник'), findsNothing);
    expect(find.text('Карточка ленты'), findsWidgets);
    await tester.tap(find.byTooltip('Назад'));
    expect(backTapped, isTrue);
  });
}
