import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/edit_message_dialog.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
        'editor unchanged and failed save preserve lifetime/draft dark=$dark',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      bool? result;
      await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(
            brightness: dark ? Brightness.dark : Brightness.light),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(1.5),
                viewInsets: const EdgeInsets.only(bottom: 240)),
            child: child!),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showEditMessageDialog(context,
                          initialText: 'Исходный текст', onSave: (_) async {
                        calls++;
                        throw StateError('local failure');
                      });
                    },
                    child: const Text('Открыть')))),
      ));
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(result, false);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Изменённый текст');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось изменить сообщение'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Изменённый текст');
      expect(calls, 1);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(result, false);
      expect(tester.takeException(), isNull);
    });
  }
  for (final closePending in [false, true]) {
    testWidgets(
        'editor pending save, repeat tap and route disposal close=$closePending',
        (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final pending = Completer<void>();
      var calls = 0;
      bool? result;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showEditMessageDialog(context,
                          initialText: 'Исходный', onSave: (_) async {
                        calls++;
                        await pending.future;
                      });
                    },
                    child: const Text('Открыть')))),
      ));
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Новый');
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      expect(calls, 1);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      if (closePending) {
        navigator.currentState!.pop(false);
        await tester.pumpAndSettle();
        pending.completeError(StateError('late local failure'));
      } else {
        pending.complete();
      }
      await tester.pumpAndSettle();
      expect(result, !closePending);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
