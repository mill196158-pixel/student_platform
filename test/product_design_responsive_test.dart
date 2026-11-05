import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

class StatefulProbe extends StatefulWidget {
  const StatefulProbe({super.key});
  @override
  State<StatefulProbe> createState() => _StatefulProbeState();
}

class _StatefulProbeState extends State<StatefulProbe> {
  int count = 0;
  @override
  Widget build(BuildContext context) => TextButton(
      onPressed: () => setState(() => count++), child: Text('Count $count'));
}

void main() {
  testWidgets('resizing navigation preserves content state and actions',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    int selected = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(),
        home: StudentWorkspaceFrame(
            index: 0,
            onSelected: (index) => selected = index,
            child: const StatefulProbe())));
    await tester.tap(find.text('Count 0'));
    await tester.pump();
    for (final width in [390.0, 834.0, 1440.0, 390.0]) {
      tester.view.physicalSize = Size(width, width == 834 ? 390 : 900);
      await tester.pumpAndSettle();
      expect(find.text('Count 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byType(NavigationRail),
          width >= 760 ? findsOneWidget : findsNothing);
    }
    await tester.tap(find.text('База'));
    await tester.pump();
    expect(selected, 1);
  });
  testWidgets('shared form and dialog remain usable with enlarged text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(MaterialApp(
          theme: ProductTheme.build(brightness: brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!),
          home: Scaffold(
              body: Builder(
                  builder: (context) => ListView(children: [
                        const TextField(
                            decoration: InputDecoration(
                                labelText: 'Название предмета',
                                errorText: 'Укажи название предмета')),
                        FilledButton(
                            onPressed: () => showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                        title:
                                            const Text('Сохранить изменения?'),
                                        content: const Text(
                                            'Проверь название и описание.'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('Закрыть'))
                                        ])),
                            child: const Text('Открыть')),
                      ])))));
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
    }
  });
}
