import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_editor_screen.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_repository.dart';
import 'package:student_platform_admin/shared/widgets/admin_student_phone_frame.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(
    WidgetTester tester,
    ProfileFeedRepository repo, [
    Size size = const Size(1400, 1200),
  ]) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: size.width,
            height: size.height,
            child: ProfileFeedEditorScreen(repository: repo),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists local profile feed and shows shared preview', (
    tester,
  ) async {
    await pumpEditor(tester, LocalProfileFeedRepository());

    expect(find.text('Лента профиля'), findsOneWidget);
    expect(find.text('О нас'), findsWidgets);
    expect(find.byType(StudentProfileFeedCard), findsOneWidget);
    expect(find.byType(AdminStudentPhoneFrame), findsOneWidget);
    expect(
      tester
          .widget<StudentBottomNav>(find.byType(StudentBottomNav))
          .currentIndex,
      4,
    );
    expect(find.textContaining('Новости не копируются'), findsOneWidget);
  });

  testWidgets('title edits update profile preview live', (tester) async {
    await pumpEditor(tester, LocalProfileFeedRepository());
    await tester.tap(find.text('Новая карточка'));
    await tester.pumpAndSettle();
    final title = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    await tester.enterText(title, 'Новая карточка профиля');
    await tester.pump();

    expect(find.text('Новая карточка профиля'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile frame does not overflow at narrow width', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      LocalProfileFeedRepository(),
      const Size(760, 900),
    );
    expect(find.byType(AdminStudentPhoneFrame), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('create draft uses local repository', (tester) async {
    final repo = LocalProfileFeedRepository();
    await pumpEditor(tester, repo);

    await tester.tap(find.text('Новая карточка'));
    await tester.pumpAndSettle();

    final items = await repo.list();
    expect(items.any((e) => e.status.name == 'draft'), isTrue);
    expect(find.textContaining('размещение «лента профиля»'), findsOneWidget);
    expect(find.text('Preview аудитории'), findsOneWidget);
    expect(find.textContaining('Черновик'), findsWidgets);
  });

  testWidgets('invalid create does not write', (tester) async {
    final repo = LocalProfileFeedRepository();
    await pumpEditor(tester, repo);

    // Need a draft selected so payload fields are editable.
    await tester.tap(find.text('Новая карточка'));
    await tester.pumpAndSettle();
    final before = (await repo.list()).length;

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), ' ');
    await tester.enterText(fields.at(1), ' ');
    await tester.enterText(fields.at(2), ' ');
    await tester.tap(find.text('Новая карточка'));
    await tester.pumpAndSettle();

    expect(await repo.list(), hasLength(before));
    expect(find.textContaining('запись не создана'), findsOneWidget);
  });

  test('local previewAudience returns safe counts', () async {
    final repo = LocalProfileFeedRepository();
    final items = await repo.list();
    final preview = await repo.previewAudience(items.first.id);
    expect(preview.recipientCount, greaterThan(0));
    expect(preview.audienceMode, 'all');
  });
}
