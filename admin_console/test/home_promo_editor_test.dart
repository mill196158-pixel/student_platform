import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_editor_screen.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('Admin Home promo preview uses StudentHomePromoCard',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(StudentHomePromoCard), findsOneWidget);
    expect(find.text('Застрял с заданием?'), findsWidgets);
    expect(find.textContaining('Preview'), findsOneWidget);
  });

  testWidgets('editing title updates shared preview renderer', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePromoEditorScreen(
            repository: LocalHomePromoRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.labelText == 'Заголовок',
    );
    expect(titleField, findsOneWidget);
    await tester.enterText(titleField, 'Новый заголовок');
    await tester.pump();

    expect(find.text('Новый заголовок'), findsWidgets);
    expect(find.byType(StudentHomePromoCard), findsOneWidget);
  });
}
