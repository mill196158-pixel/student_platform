import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/composer.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('composer keeps one input surface in $brightness', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var sent = 0;
      await tester.pumpWidget(MaterialApp(
        theme: ProductTheme.build(brightness: brightness),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              controller: controller,
              pickedImagePath: null,
              onOpenEmoji: () {},
              onSend: () => sent++,
              onClearPicked: () {},
              onPickImage: () async {},
              onAttachFile: () {},
              attachedFiles: const [],
              onRemoveFile: (_) {},
              onAddFile: (_) {},
              leftButton: const SizedBox(width: 48, height: 48),
            ),
          ),
        ),
      ));
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.filled, isFalse);
      expect(field.decoration!.focusedBorder, InputBorder.none);
      await tester.enterText(find.byType(TextField), 'Проверка');
      await tester.tap(find.byTooltip('Отправить'));
      expect(sent, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
