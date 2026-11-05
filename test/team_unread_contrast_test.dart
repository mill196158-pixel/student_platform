import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/learning_screen.dart';
import 'package:student_platform/src/ui/learning/models/team.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('team unread and title retain readable contrast in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(MaterialApp(theme: ProductTheme.build(brightness: brightness), home:
        const Scaffold(body: StudentTeamTile(Team(id: 'local', name: 'Учебная команда',
          teacher: 'Преподаватель', groupCode: 'Тест', icon: 'T', unread: 7)))));
      await tester.pumpAndSettle();
      final badge = tester.widgetList<Container>(find.byType(Container)).singleWhere(
        (w) => w.child is Text && (w.child! as Text).data == '7');
      final foreground = (badge.child! as Text).style!.color!;
      final background = (badge.decoration! as BoxDecoration).color!;
      final a = foreground.computeLuminance(), b = background.computeLuminance();
      expect((math.max(a, b) + .05) / (math.min(a, b) + .05), greaterThanOrEqualTo(4.5));
      final title = tester.widget<Text>(find.text('Учебная команда'));
      final tile = tester.widgetList<Container>(find.byType(Container)).firstWhere(
        (w) => w.child is Row);
      final surface = (tile.decoration! as BoxDecoration).color!;
      final x = title.style!.color!.computeLuminance(), y = surface.computeLuminance();
      expect((math.max(x, y) + .05) / (math.min(x, y) + .05), greaterThanOrEqualTo(4.5));
      expect(tester.takeException(), isNull);
    }
  });
}
