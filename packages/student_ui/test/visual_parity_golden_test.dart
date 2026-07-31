import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

import 'student_home_promo_variants_test.dart' show kTestPngBytes;

void main() {
  const goldenSizes = <Size>[
    Size(390, 844),
    Size(430, 932),
  ];

  Future<void> pumpGolden(
    WidgetTester tester, {
    required Size surfaceSize,
    required Widget child,
  }) async {
    await tester.binding.setSurfaceSize(surfaceSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: studentPlatformLightTheme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('visual parity goldens', () {
    for (final size in goldenSizes) {
      final tag = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('home image_full $tag', (tester) async {
        await pumpGolden(
          tester,
          surfaceSize: size,
          child: StudentHomePromoCard(
            payload: HomePromoPayload.demoStuckWithAssignment.copyWith(
              title: 'Полноэкранная promo',
              cardVariant: 'image_full',
            ),
            imageBytes: kTestPngBytes,
          ),
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/home_image_full_$tag.png'),
        );
      });

      testWidgets('home image_overlay $tag', (tester) async {
        await pumpGolden(
          tester,
          surfaceSize: size,
          child: StudentHomePromoCard(
            payload: HomePromoPayload.demoStuckWithAssignment.copyWith(
              title: 'Overlay promo',
              cardVariant: 'image_overlay',
              overlayOpacity: 0.5,
            ),
            imageBytes: kTestPngBytes,
          ),
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/home_image_overlay_$tag.png'),
        );
      });

      testWidgets('home end_of_page promo $tag', (tester) async {
        final now = DateTime(2026, 7, 21);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: studentPlatformLightTheme(),
            home: StudentHomeView(
              data: StudentHomeData(
                profile: const StudentHomeProfile(
                  name: 'Анна',
                  groupName: 'ИСТ-401',
                ),
                currentDate: now,
                lessons: const [],
                assignments: const [],
                news: const [],
                totalLessonsToday: 0,
                assignmentsCount: 0,
              ),
              homePromoPlacements: [
                StudentHomePromoPlacement(
                  payload: HomePromoPayload.demoStuckWithAssignment.copyWith(
                    title: 'Promo в конце',
                    homeSlot: 'end_of_page',
                    cardVariant: 'gradient_text',
                  ),
                  slot: 'end_of_page',
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(StudentHomeView),
          matchesGoldenFile('goldens/home_end_of_page_$tag.png'),
        );
      });

      testWidgets('profile preview with diary $tag', (tester) async {
        await pumpGolden(
          tester,
          surfaceSize: size,
          child: const StudentProfileScreenPreview(
            displayName: 'Анна',
            groupLabel: 'ИСТ-401',
            universityLabel: 'СПБГАСУ',
            messagesBadge: 3,
            friendsBadge: 1,
          ),
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/profile_diary_$tag.png'),
        );
      });

      testWidgets('jobs board list $tag', (tester) async {
        const vacancy = ManagedVacancyCard(
          id: 'vac-1',
          origin: ContentOrigin.demo,
          payload: VacancyCardPayload(
            title: 'Junior Flutter Developer',
            companyName: 'Campus Lab',
            summary: 'Помощь с мобильным приложением.',
            descriptionFull: 'Полное описание вакансии для golden.',
          ),
        );
        await pumpGolden(
          tester,
          surfaceSize: size,
          child: const StudentJobsBoardView(
            cards: [vacancy],
            showProposeActions: true,
          ),
        );
        // after compact layout
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/jobs_board_$tag.png'),
        );
      });

      testWidgets('jobs board list before baseline exists $tag',
          (tester) async {
        // Keeps the pre-density screenshot in the repo for before/after review.
        expect(
          File('test/goldens/jobs_board_before_$tag.png').existsSync(),
          isTrue,
        );
      });

      testWidgets('jobs board detail $tag', (tester) async {
        const vacancy = ManagedVacancyCard(
          id: 'vac-1',
          origin: ContentOrigin.demo,
          payload: VacancyCardPayload(
            title: 'Junior Flutter Developer',
            companyName: 'Campus Lab',
            summary: 'Помощь с мобильным приложением.',
            descriptionFull: 'Полное описание вакансии для golden.',
          ),
        );
        await pumpGolden(
          tester,
          surfaceSize: size,
          child: const StudentJobsBoardView(
            cards: [vacancy],
            detailPayload: vacancy,
          ),
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/jobs_detail_$tag.png'),
        );
      });

      testWidgets('help browse list $tag', (tester) async {
        const article = ManagedReferenceArticle(
          id: 'art-1',
          title: 'Как войти в ЛК',
          schemaVersion: 2,
          origin: ContentOrigin.admin,
          sortOrder: 0,
          categoryId: 'cat-1',
          categoryTitle: 'Доступы',
          payload: ReferenceArticlePayload(
            iconKey: 'help',
            shortText: 'Короткая подсказка по входу в личный кабинет',
            blocks: [
              ReferenceTextBlock(
                text: 'Откройте сайт университета и войдите.',
              ),
            ],
          ),
        );
        await pumpGolden(
          tester,
          surfaceSize: size,
          child: const StudentHelpBrowseView(
            articles: [article],
          ),
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/help_browse_$tag.png'),
        );
      });

      testWidgets('help browse list before baseline exists $tag',
          (tester) async {
        expect(
          File('test/goldens/help_browse_before_$tag.png').existsSync(),
          isTrue,
        );
      });

      testWidgets('help browse article $tag', (tester) async {
        const article = ManagedReferenceArticle(
          id: 'art-1',
          title: 'Как войти в ЛК',
          schemaVersion: 2,
          origin: ContentOrigin.admin,
          sortOrder: 0,
          categoryId: 'cat-1',
          categoryTitle: 'Доступы',
          payload: ReferenceArticlePayload(
            iconKey: 'help',
            shortText: 'Короткая подсказка',
            blocks: [
              ReferenceTextBlock(
                text: 'Откройте сайт университета и войдите.',
              ),
            ],
          ),
        );
        await pumpGolden(
          tester,
          surfaceSize: size,
          child: const StudentHelpBrowseView(
            articles: [article],
            selectedArticle: article,
          ),
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/help_article_$tag.png'),
        );
      });
    }
  });
}
