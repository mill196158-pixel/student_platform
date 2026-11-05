import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/profile/theme_mode_picker.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('phone theme picker fits large text in $brightness',
        (tester) async {
      _setViewport(tester, const Size(320, 568));
      ThemeMode? picked;

      await tester.pumpWidget(_app(brightness, (mode) => picked = mode));
      await tester.tap(find.text('Открыть тему'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      final selected = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Как на устройстве'),
      );
      expect(selected.selected, isTrue);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Тёмная'));
      await tester.pumpAndSettle();
      expect(picked, ThemeMode.dark);
      expect(find.byType(BottomSheet), findsNothing);
    });
  }

  testWidgets('desktop picker has a bounded dialog and supports Escape',
      (tester) async {
    _setViewport(tester, const Size(1440, 900));
    ThemeMode? picked = ThemeMode.light;

    await tester.pumpWidget(_app(Brightness.light, (mode) => picked = mode));
    await tester.tap(find.text('Открыть тему'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.getSize(find.byType(ListTile).first).width, lessThan(420));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(picked, isNull);
  });
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(Brightness brightness, ValueChanged<ThemeMode?> onPick) {
  return MaterialApp(
    theme: ProductTheme.build(brightness: brightness),
    builder: (context, child) => MediaQuery.withClampedTextScaling(
      minScaleFactor: 1.5,
      maxScaleFactor: 1.5,
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            onPick(await showThemeModePicker(context, ThemeMode.system));
          },
          child: const Text('Открыть тему'),
        ),
      ),
    ),
  );
}
