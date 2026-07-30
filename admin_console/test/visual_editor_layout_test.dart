import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_list_panel.dart';
import 'package:student_platform_admin/features/content/shared/visual_editor_shell.dart';

void main() {
  for (final width in [1280.0, 1440.0, 1920.0]) {
    testWidgets('status tabs stay single-line at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VisualEditorShell(
              title: 'Тест',
              listTab: VisualEditorListTab.published,
              tabCounts: const VisualEditorTabCounts(
                published: 2,
                drafts: 1,
                archived: 0,
              ),
              onTabChanged: (_) {},
              listBuilder: (_) => VisualEditorListPanel(
                tab: VisualEditorListTab.published,
                tabCounts: const VisualEditorTabCounts(
                  published: 2,
                  drafts: 1,
                  archived: 0,
                ),
                items: const [
                  VisualEditorListItem(
                    id: '1',
                    title: 'Длинное название карточки для списка',
                    isDemo: true,
                  ),
                ],
                selectedId: '1',
                onTabChanged: (_) {},
                onSelected: (_) {},
              ),
              previewBuilder: (_) => const ColoredBox(color: Colors.white),
              propertiesBuilder: (_) => const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Опубликовано'), findsWidgets);
      expect(find.textContaining('Черновики'), findsWidgets);
      expect(find.textContaining('Архив'), findsWidgets);

      // Labels must not be letter-wrapped (no single-letter Text widgets for tabs).
      expect(find.text('О'), findsNothing);
      expect(find.text('п'), findsNothing);
    });
  }
}
