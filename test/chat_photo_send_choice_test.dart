import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/photo_send_choice.dart';

void main() {
  testWidgets('photo, original and cancellation are distinct choices',
      (tester) async {
    bool? result;
    var completed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await choosePhotoSendMode(context);
          completed = true;
        },
        child: const Text('Выбрать'),
      ),
    ))));
    for (final choice in ['Фото — уменьшить', 'Оригинал без изменений']) {
      completed = false;
      await tester.tap(find.text('Выбрать'));
      await tester.pumpAndSettle();
      expect(find.textContaining('геоданные'), findsOneWidget);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, choice == 'Фото — уменьшить');
    }
    completed = false;
    await tester.tap(find.text('Выбрать'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });
}
