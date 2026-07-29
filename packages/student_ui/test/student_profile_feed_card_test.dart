import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('renders payload and demo badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 160,
            child: StudentProfileFeedCard(
              payload: ProfileFeedPayload.demoFeed.first,
              showDemoBadge: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Пример'), findsOneWidget);
    expect(find.text('О нас'), findsOneWidget);
    expect(find.text('Открыть'), findsOneWidget);
  });

  testWidgets('carousel exposes tap for each card', (tester) async {
    final tapped = <String>[];
    final cards = [
      for (var i = 0; i < ProfileFeedPayload.demoFeed.length; i++)
        ManagedProfileFeedCard(
          id: 'c$i',
          origin: ContentOrigin.demo,
          sortOrder: i,
          priority: 0,
          payload: ProfileFeedPayload.demoFeed[i],
          showDemoBadge: true,
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentProfileFeedCarousel(
            cards: cards,
            onTap: (card) => tapped.add(card.id),
          ),
        ),
      ),
    );
    await tester.tap(find.text('О нас'));
    expect(tapped, ['c0']);
  });

  testWidgets('visible callback fires on demo→managed replacement',
      (tester) async {
    final visible = <String>[];
    final demo = [
      ManagedProfileFeedCard(
        id: 'demo-0',
        origin: ContentOrigin.demo,
        sortOrder: 0,
        priority: 0,
        payload: ProfileFeedPayload.demoFeed.first,
        showDemoBadge: true,
      ),
    ];
    final managed = [
      ManagedProfileFeedCard(
        id: 'managed-0',
        origin: ContentOrigin.admin,
        sortOrder: 0,
        priority: 0,
        payload: ProfileFeedPayload.demoFeed.first,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentProfileFeedCarousel(
            cards: demo,
            onTap: (_) {},
            onVisibleCard: (card) => visible.add(card.id),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(visible, ['demo-0']);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentProfileFeedCarousel(
            cards: managed,
            onTap: (_) {},
            onVisibleCard: (card) => visible.add(card.id),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(visible, ['demo-0', 'managed-0']);
  });
}
