import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/news/admin_image_store.dart';
import 'package:student_platform_admin/features/content/news/news_item.dart';
import 'package:student_platform_admin/features/content/news/news_editor_screen.dart';
import 'package:student_platform_admin/features/content/news/news_repository.dart';
import 'package:student_platform_admin/shared/widgets/admin_student_phone_frame.dart';
import 'package:student_ui/student_ui.dart';

LocalNewsRepository _seedRepo() {
  return LocalNewsRepository(
    seed: const [
      NewsItem(
        id: 'local-1',
        title: 'Градиентная новость',
        subtitle: 'Первая',
        body: 'Тело первой новости для просмотра истории.',
        variant: StudentHomeNewsVariant.gradientText,
        colors: [Color(0xFF7367F0), Color(0xFFB784F7)],
        status: NewsStatus.published,
      ),
      NewsItem(
        id: 'local-2',
        title: 'Новость с текстом поверх',
        subtitle: 'Вторая',
        body: 'Тело второй новости.',
        variant: StudentHomeNewsVariant.imageOverlay,
        colors: [Color(0xFF246B8E), Color(0xFF54B7AD)],
      ),
    ],
  );
}

void main() {
  testWidgets('editor renders variant cards in the phone preview', (
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
            repository: _seedRepo(),
            imageStore: LocalAdminImageStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StudentHomeView), findsOneWidget);
    expect(find.byType(AdminStudentPhoneFrame), findsOneWidget);
    // Phone preview shows only published schedule-active cards (not drafts).
    expect(find.byType(StudentHomeNewsCard), findsOneWidget);
  });

  testWidgets('tapping a preview card opens the full story sheet', (
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
            repository: _seedRepo(),
            imageStore: LocalAdminImageStore(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byType(StudentHomeNewsCard).first,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(find.byType(StudentNewsStorySheet), findsOneWidget);
    expect(find.text('Отлично'), findsOneWidget);
    expect(find.text('Что нового'), findsOneWidget);
  });
}
