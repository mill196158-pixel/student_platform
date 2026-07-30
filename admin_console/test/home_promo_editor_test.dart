import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_editor_screen.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_repository.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_list_panel.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_shell.dart';
import 'package:student_ui/student_ui.dart';

Finder get _createButton => find.byTooltip('Создать черновик');

void main() {
  testWidgets(
    'Home promo editor uses VisualEditorShell and StudentHomePromoCard',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(VisualEditorShell), findsOneWidget);
      expect(find.byType(VisualEditorListPanel), findsOneWidget);
      expect(find.byType(StudentHomePromoCard), findsOneWidget);
      expect(find.text('Застрял с заданием?'), findsWidgets);
      expect(find.text('Promo-карточки'), findsOneWidget);
      expect(find.textContaining('Опубликовано'), findsWidgets);
      expect(find.textContaining('Черновики'), findsWidgets);
      expect(find.textContaining('Архив'), findsWidgets);
    },
  );

  testWidgets('demo badge appears for seeded demo item', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Демо'), findsWidgets);
    expect(find.text('Пример'), findsOneWidget);
  });

  testWidgets('editing title updates shared preview renderer', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    expect(titleField, findsOneWidget);
    await tester.enterText(titleField, 'Новый заголовок');
    await tester.pump();

    expect(find.text('Новый заголовок'), findsWidgets);
    expect(find.text('Есть правки'), findsOneWidget);
  });

  testWidgets('dirty warning appears after unsaved edits', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(repository: LocalHomePromoRepository()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Есть правки'), findsNothing);

    await tester.tap(_createButton);
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Заголовок',
    );
    await tester.enterText(titleField, 'Изменено');
    await tester.pump();

    expect(find.text('Есть правки'), findsOneWidget);
    expect(
      find.textContaining('несохранённые изменения', findRichText: true),
      findsWidgets,
    );
  });

  test('local working draft begin save publish flow', () async {
    final repo = LocalHomePromoRepository();
    final published = (await repo.list()).first;
    expect(published.isPublished, isTrue);

    final editing = await repo.beginEdit(published.id);
    expect(editing.hasWorkingDraft, isTrue);

    final saved = await repo.saveWorkingDraft(
      editing.copyWith(title: 'Новый promo заголовок'),
      expectedDraftRowVersion: editing.workingDraftRowVersion!,
    );
    expect(saved.title, 'Новый promo заголовок');

    final applied = await repo.publishWorkingDraft(
      published.id,
      expectedDraftRowVersion: saved.workingDraftRowVersion!,
    );
    expect(applied.title, 'Новый promo заголовок');
    expect(applied.hasWorkingDraft, isFalse);
  });

  test('local working draft discard clears overlay', () async {
    final repo = LocalHomePromoRepository();
    final published = (await repo.list()).first;
    final editing = await repo.beginEdit(published.id);
    await repo.saveWorkingDraft(
      editing.copyWith(title: 'Черновик promo'),
      expectedDraftRowVersion: editing.workingDraftRowVersion!,
    );
    final restored = await repo.discardWorkingDraft(published.id);
    expect(restored.title, published.title);
    expect(restored.hasWorkingDraft, isFalse);
  });
}
