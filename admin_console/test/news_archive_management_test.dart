import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/news/admin_image_store.dart';
import 'package:student_platform_admin/features/content/news/news_editor_screen.dart';
import 'package:student_platform_admin/features/content/news/news_item.dart';
import 'package:student_platform_admin/features/content/news/news_preview.dart';
import 'package:student_platform_admin/features/content/news/news_repository.dart';
import 'package:student_platform_admin/shared/widgets/publication_status_badge.dart';
import 'package:student_ui/student_ui.dart';

NewsItem _item({
  required String id,
  required String title,
  required NewsStatus status,
  bool isHidden = false,
  DateTime? startsAt,
  DateTime? endsAt,
  String? imagePath,
  int sortOrder = 0,
}) {
  return NewsItem(
    id: id,
    title: title,
    subtitle: 'Подзаголовок $id',
    body: 'Тело $id',
    variant: StudentHomeNewsVariant.gradientText,
    colors: const [Color(0xFF7367F0), Color(0xFFB784F7)],
    status: status,
    isHidden: isHidden,
    startsAt: startsAt,
    endsAt: endsAt,
    imagePath: imagePath,
    sortOrder: sortOrder,
    publishedAt: status == NewsStatus.published
        ? DateTime.utc(2026, 7, 22, 8)
        : null,
  );
}

LocalNewsRepository _repo() {
  return LocalNewsRepository(
    seed: [
      _item(id: 'pub-1', title: 'Опубликованная', status: NewsStatus.published),
      _item(id: 'draft-1', title: 'Черновик', status: NewsStatus.draft),
      _item(id: 'arch-1', title: 'Архивная', status: NewsStatus.archived),
      _item(
        id: 'hidden-pub',
        title: 'Скрытая опубликованная',
        status: NewsStatus.published,
        isHidden: true,
      ),
      _item(
        id: 'future-pub',
        title: 'Будущая',
        status: NewsStatus.published,
        startsAt: DateTime.utc(2099, 1, 1),
      ),
    ],
  );
}

void main() {
  group('publishedPreviewItems', () {
    test(
      'includes only schedule-active published, excludes draft/archived/hidden',
      () async {
        final now = DateTime.utc(2026, 7, 22, 12);
        final items = await _repo().listNews();
        final parts = partitionAdminNews(items, now: now);

        expect(parts.publishedPreviewItems.map((e) => e.id), ['pub-1']);
        expect(
          parts.publishedPreviewItems.any((e) => e.id == 'draft-1'),
          isFalse,
        );
        expect(
          parts.publishedPreviewItems.any((e) => e.id == 'arch-1'),
          isFalse,
        );
        expect(
          parts.publishedPreviewItems.any((e) => e.id == 'hidden-pub'),
          isFalse,
        );
        expect(
          parts.publishedPreviewItems.any((e) => e.id == 'future-pub'),
          isFalse,
        );
      },
    );

    test('each item appears in exactly one admin tab partition', () async {
      final items = await _repo().listNews();
      final parts = partitionAdminNews(items);
      final ids = <String>{
        ...parts.published.map((e) => e.id),
        ...parts.drafts.map((e) => e.id),
        ...parts.archived.map((e) => e.id),
      };
      expect(ids.length, parts.allAdminItems.length);
      expect(parts.published.every((e) => e.isPublished), isTrue);
      expect(parts.drafts.every((e) => e.isDraft), isTrue);
      expect(parts.archived.every((e) => e.isArchived), isTrue);
    });
  });

  group('LocalNewsRepository archive delete', () {
    test('restore archived → draft', () async {
      final repo = _repo();
      final restored = await repo.restoreArchived('arch-1');
      expect(restored.status, NewsStatus.draft);
      expect((await repo.getNews('arch-1')).status, NewsStatus.draft);
    });

    test('permanent delete allowed only for archived', () async {
      final repo = _repo();
      await expectLater(
        repo.deleteArchived('pub-1'),
        throwsA(isA<NewsRepositoryException>()),
      );
      await expectLater(
        repo.deleteArchived('draft-1'),
        throwsA(isA<NewsRepositoryException>()),
      );

      final result = await repo.deleteArchived('arch-1');
      expect(result.id, 'arch-1');
      expect(result.previousStatus, NewsStatus.archived);
      expect(repo.auditTombstones, isNotEmpty);
      expect(repo.auditTombstones.first['title'], 'Архивная');
      await expectLater(
        repo.getNews('arch-1'),
        throwsA(isA<NewsRepositoryException>()),
      );
    });

    test('versions are removed with the archived post', () async {
      final repo = _repo();
      expect(repo.versionsFor('arch-1'), isNotEmpty);
      await repo.deleteArchived('arch-1');
      expect(repo.versionsFor('arch-1'), isEmpty);
      expect(await repo.listVersions('arch-1'), isEmpty);
    });

    test('shared image_path is not offered for Storage delete', () async {
      const shared = 'news/shared.jpg';
      final repo = LocalNewsRepository(
        seed: [
          _item(
            id: 'arch-shared',
            title: 'Архив с общим файлом',
            status: NewsStatus.archived,
            imagePath: shared,
          ),
          _item(
            id: 'draft-shared',
            title: 'Черновик с тем же файлом',
            status: NewsStatus.draft,
            imagePath: shared,
          ),
        ],
      );

      final result = await repo.deleteArchived('arch-shared');
      expect(result.candidateMediaPaths, contains(shared));
      expect(result.mediaPathsToDelete, isEmpty);
    });

    test('orphan image_path is returned for Storage delete', () async {
      final repo = LocalNewsRepository(
        seed: [
          _item(
            id: 'arch-orphan',
            title: 'Архив с orphan',
            status: NewsStatus.archived,
            imagePath: 'news/orphan.jpg',
          ),
        ],
      );
      final result = await repo.deleteArchived('arch-orphan');
      expect(result.mediaPathsToDelete, ['news/orphan.jpg']);
    });

    test('audit tombstone remains after delete', () async {
      final repo = _repo();
      await repo.deleteArchived('arch-1');
      expect(repo.auditTombstones.single['id'], 'arch-1');
      expect(repo.auditTombstones.single['previous_status'], 'archived');
    });
  });

  group('NewsEditorScreen archive UI', () {
    testWidgets('phone preview excludes draft and archived', (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsEditorScreen(
              repository: _repo(),
              imageStore: LocalAdminImageStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(StudentHomeNewsCard), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(StudentHomeView),
          matching: find.text('Опубликованная'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(StudentHomeView),
          matching: find.text('Черновик'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(StudentHomeView),
          matching: find.text('Архивная'),
        ),
        findsNothing,
      );
    });

    testWidgets('selecting archived does not add it to phone preview', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsEditorScreen(
              repository: _repo(),
              imageStore: LocalAdminImageStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Архив'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Архивная').first);
      await tester.pumpAndSettle();

      expect(find.byType(StudentHomeNewsCard), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(StudentHomeView),
          matching: find.text('Архивная'),
        ),
        findsNothing,
      );
      expect(find.text('Восстановить как черновик'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('delete-archived-forever')),
        findsOneWidget,
      );
    });

    testWidgets('status badges are visible for published tab', (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsEditorScreen(
              repository: _repo(),
              imageStore: LocalAdminImageStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PublicationStatusBadge), findsWidgets);
      expect(find.text('Опубликован'), findsWidgets);
    });

    testWidgets('delete confirms, blocks double submit, selects next', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = LocalNewsRepository(
        seed: [
          _item(id: 'arch-a', title: 'Архив A', status: NewsStatus.archived),
          _item(id: 'arch-b', title: 'Архив B', status: NewsStatus.archived),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NewsEditorScreen(
              repository: repo,
              imageStore: LocalAdminImageStore(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Архив'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Архив A').first);
      await tester.pumpAndSettle();

      final deleteButton = find.byKey(
        const ValueKey('delete-archived-forever'),
      );
      expect(deleteButton, findsOneWidget);

      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      expect(find.text('Удалить новость навсегда?'), findsOneWidget);
      expect(
        find.text(
          'Новость, её версии и статистику просмотров восстановить будет нельзя',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Удалить навсегда'));
      await tester.pump();
      // Second tap while in-flight / dialog closing must not throw or double-delete.
      await tester.tap(find.text('Удалить навсегда'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('Новость удалена'), findsOneWidget);
      expect(find.text('Архив A'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('Архив B'),
        ),
        findsWidgets,
      );
      expect(await repo.listNews(), hasLength(1));
      expect((await repo.listNews()).single.id, 'arch-b');
    });
  });
}
