import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/emoji_sheet.dart';

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
          'emoji sheet layout and local cursor insertion $size dark=$dark',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = TextEditingController(text: 'abcde');
        addTearDown(controller.dispose);
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
                      onPressed: () =>
                          showEmojiPickerSheet(context, controller: controller),
                      child: const Text('Открыть')))),
        ));
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(EmojiPicker)).width,
            lessThanOrEqualTo(600));
        expect(
            tester.getSize(find.byType(EmojiPicker)).height, greaterThan(100));
        expect(controller.text, 'abcde');
        final picker = tester.widget<EmojiPicker>(find.byType(EmojiPicker));
        expect(picker.config.locale.languageCode, 'ru');
        controller.selection =
            const TextSelection(baseOffset: 1, extentOffset: 3);
        picker.onEmojiSelected!(Category.SMILEYS, const Emoji('😀', 'улыбка'));
        expect(controller.text, 'a😀de');
        expect(controller.selection.baseOffset, 3);
        controller.selection = const TextSelection.collapsed(offset: -1);
        picker.onEmojiSelected!(Category.SMILEYS, const Emoji('😀', 'улыбка'));
        expect(controller.text, 'a😀de😀');
        expect(controller.selection.baseOffset, 7);
        await tester.tap(find.byTooltip('Клавиатура'));
        await tester.pumpAndSettle();
        expect(find.byType(EmojiPicker), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
