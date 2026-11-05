import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/subjects/subject_card_editor_screen.dart';
import 'package:student_platform_admin/features/academic/subjects/subjects_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows shared preview and editorial guidance', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1600,
          height: 1400,
          child: SubjectCardEditorScreen(
            repository: LocalSubjectsRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Описание, материалы'), findsOneWidget);

    expect(find.byType(StudentSubjectCardPreview), findsOneWidget);
    expect(find.text('Предпросмотр'), findsOneWidget);
    expect(find.text('Не выбран'), findsOneWidget);
    expect(find.textContaining('UUID через запятую'), findsNothing);

    final leftScrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Порядок секций'),
      300,
      scrollable: leftScrollable,
    );
    expect(find.text('Порядок секций'), findsOneWidget);
  });

  testWidgets('does not auto-select first offering', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final repo = LocalSubjectsRepository();
    final subject = (await repo.list()).first;
    repo.seedOffering(
      SubjectOfferingAdminItem(
        id: 'off-auto',
        subjectId: subject.id,
        displayName: 'Offering Auto',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1600,
          height: 1400,
          child: SubjectCardEditorScreen(
            repository: repo,
            item: subject,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Не выбран'), findsOneWidget);
    final leftScrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.textContaining('Выберите offering, чтобы редактировать'),
      400,
      scrollable: leftScrollable,
    );
    expect(
      find.textContaining('Выберите offering, чтобы редактировать'),
      findsOneWidget,
    );
  });
  testWidgets('phone editor keeps draft while switching preview tabs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(theme: ProductTheme.build(), home:
      SubjectCardEditorScreen(repository: LocalSubjectsRepository())));
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, 'Название');
    await tester.ensureVisible(name);
    await tester.enterText(name, 'Локальный учебный предмет');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.tap(find.text('Предпросмотр').first);
    await tester.pumpAndSettle();
    expect(find.text('Локальный учебный предмет'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Редактор'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(name).controller!.text, 'Локальный учебный предмет');
    expect(tester.takeException(), isNull);
  });

}
