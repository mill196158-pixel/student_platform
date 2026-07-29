import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/academic/subjects/subject_card_editor_screen.dart';
import 'package:student_platform_admin/features/academic/subjects/subjects_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows shared preview and 16.1 foundation copy', (tester) async {
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

    expect(find.textContaining('16.1: текст'), findsOneWidget);
    expect(find.textContaining('subject-media Edge'), findsOneWidget);
    expect(find.byType(StudentSubjectCardPreview), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
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
}
