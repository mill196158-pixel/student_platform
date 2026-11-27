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

  testWidgets('selectedId moves carousel to matching card', (tester) async {
    final visible = <String>[];
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
            selectedId: 'c1',
            onTap: (_) {},
            onVisibleCard: (card) => visible.add(card.id),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(visible, ['c1']);
    expect(find.text('Расписание занятий'), findsOneWidget);
  });

  testWidgets('swipe notifies onVisibleCard with visible card id',
      (tester) async {
    final visible = <String>[];
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
          body: SizedBox(
            width: 400,
            child: StudentProfileFeedCarousel(
              cards: cards,
              onTap: (_) {},
              onVisibleCard: (card) => visible.add(card.id),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(visible, ['c0']);

    await tester.drag(find.byType(PageView), const Offset(-250, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(visible, ['c0', 'c1']);
  });

  testWidgets('profile carousel saves space and keeps the image and gestures',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tapped = <String>[];
    final visible = <String>[];
    final cards = [
      ManagedProfileFeedCard(
        id: 'image',
        origin: ContentOrigin.admin,
        sortOrder: 0,
        priority: 0,
        payload: ProfileFeedPayload.demoFeed.first.copyWith(
          cardVariant: 'image_top_text',
        ),
        imageBytes: _pngBytes,
      ),
      ManagedProfileFeedCard(
        id: 'text',
        origin: ContentOrigin.admin,
        sortOrder: 1,
        priority: 0,
        payload: ProfileFeedPayload.demoFeed[1],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: ProductTheme.build(),
        home: Scaffold(
          body: StudentProfileFeedCarousel(
            cards: cards,
            onTap: (card) => tapped.add(card.id),
            onVisibleCard: (card) => visible.add(card.id),
          ),
        ),
      ),
    );

    final page = find.byType(PageView);
    expect(tester.getSize(page).height, 184);
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.cover);
    expect(tester.getSize(find.byType(Image)).height, 80);
    await tester.tap(find.text('О нас'));
    await tester.drag(page, const Offset(-240, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Расписание занятий'));
    expect(tapped, ['image', 'text']);
    expect(visible, ['image', 'text']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact promo variants fit at 320 px with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const action = 'Открыть подробные материалы';
    for (final variant in [
      'gradient_text',
      'image_full',
      'image_overlay',
      'image_top_text',
      'compact_icon',
      'accent_info',
      'no_image',
    ]) {
      await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: Scaffold(
          body: StudentProfileFeedCarousel(
            cards: [
              ManagedProfileFeedCard(
                id: variant,
                origin: ContentOrigin.demo,
                sortOrder: 0,
                priority: 0,
                showDemoBadge: true,
                payload: ProfileFeedPayload(
                  title: 'Самостоятельная подготовка к экзаменам',
                  subtitle: 'Дополнительные материалы и разбор типовых задач',
                  ctaLabel: action,
                  iconKey: 'school',
                  cardVariant: variant,
                ),
                imageBytes: _pngBytes,
              ),
            ],
            onTap: (_) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(PageView)).height, 252);
      expect(
          find.text('Самостоятельная подготовка к экзаменам'), findsOneWidget);
      if (variant != 'image_full') expect(find.text(action), findsOneWidget);
      expect(tester.takeException(), isNull, reason: variant);
    }
  });

  test('ProfileFeedPayload round-trips optional gradient colors', () {
    const payload = ProfileFeedPayload(
      title: 'T',
      subtitle: 'S',
      ctaLabel: 'C',
      gradientColors: [Color(0xFFDCD0FA), Color(0xFFC9B8F3)],
      gradientAngle: 135,
    );
    final parsed = ProfileFeedPayload.tryParse(payload.toWireJson());
    expect(parsed?.gradientColors, hasLength(2));
    expect(parsed?.gradientAngle, 135);
  });

  testWidgets('image_overlay variant renders Image when bytes provided',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 160,
            child: StudentProfileFeedCard(
              payload: ProfileFeedPayload.demoFeed.first.copyWith(
                cardVariant: 'image_overlay',
              ),
              imageBytes: _pngBytes,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsWidgets);
    expect(find.text('О нас'), findsOneWidget);
  });

  testWidgets('carousel uses payload gradient colors not index hardcode',
      (tester) async {
    const customColors = [Color(0xFFFF0000), Color(0xFF00FF00)];
    final cards = [
      ManagedProfileFeedCard(
        id: 'c0',
        origin: ContentOrigin.demo,
        sortOrder: 0,
        priority: 0,
        payload: ProfileFeedPayload.demoFeed[0].copyWith(
          gradientColors: customColors,
        ),
      ),
      ManagedProfileFeedCard(
        id: 'c1',
        origin: ContentOrigin.demo,
        sortOrder: 1,
        priority: 0,
        payload: ProfileFeedPayload.demoFeed[1].copyWith(
          gradientColors: customColors,
        ),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentProfileFeedCarousel(
            cards: cards,
            selectedId: 'c0',
            onTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final decoration = tester
        .widget<Container>(
          find.descendant(
            of: find.byType(StudentProfileFeedCard),
            matching: find.byType(Container).first,
          ),
        )
        .decoration! as BoxDecoration;

    expect(decoration.gradient, isNotNull);
    final gradient = decoration.gradient as LinearGradient;
    expect(gradient.colors, customColors);
  });
}
