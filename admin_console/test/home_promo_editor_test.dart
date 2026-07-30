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
}
