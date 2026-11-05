import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/themes/theme_service.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  test('theme starts with the system, then restores the saved choice',
      () async {
    SharedPreferences.setMockInitialValues({});
    final theme = ThemeService();
    addTearDown(theme.dispose);
    await theme.initialize();
    expect(theme.value, ThemeMode.system);

    await theme.select(ThemeMode.dark);
    final restarted = ThemeService();
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(restarted.value, ThemeMode.dark);
    await restarted.select(ThemeMode.system);
    await theme.initialize();
    expect(theme.value, ThemeMode.system);
  });

  test('an existing preference is restored until a new one is selected',
      () async {
    SharedPreferences.setMockInitialValues({'isDarkMode': true});
    final theme = ThemeService();
    addTearDown(theme.dispose);
    await theme.initialize();
    expect(theme.value, ThemeMode.dark);
    await theme.select(ThemeMode.light);
    await theme.initialize();
    expect(theme.value, ThemeMode.light);
  });

  testWidgets('holding a labeled navigation button does not show a tooltip',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: ProductTheme.build(),
      home: Scaffold(
        body: IconButton(
          tooltip: 'Назад',
          onPressed: () {},
          icon: const Icon(Icons.arrow_back),
        ),
      ),
    ));
    final button = tester.getSemantics(find.byType(IconButton));
    expect(button.getSemanticsData().tooltip, 'Назад');
    semantics.dispose();
    await tester.longPress(find.byType(IconButton));
    await tester.pump();
    expect(find.text('Назад'), findsNothing);
  });
}
