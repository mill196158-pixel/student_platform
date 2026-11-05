import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/media/chat_media_sheet.dart';
import 'package:student_platform/src/ui/learning/models/message.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('media distinguishes loading, empty tabs, errors and recovery',
      (tester) async {
    final messages = StreamController<List<Message>>();
    addTearDown(messages.close);
    await tester.pumpWidget(MaterialApp(
      theme: ProductTheme.build(brightness: Brightness.dark),
      home: ChatMediaSheet(messagesStream: messages.stream),
    ));
    expect(find.byType(ProductLoadingIndicator), findsOneWidget);
    expect(find.text('Пока нет фото'), findsNothing);
    messages.add([]);
    await tester.pumpAndSettle();
    expect(find.text('Пока нет фото'), findsOneWidget);
    await tester.tap(find.text('Файлы'));
    await tester.pumpAndSettle();
    expect(find.text('Пока нет файлов'), findsOneWidget);
    messages.addError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить медиа'), findsOneWidget);
    expect(find.byType(ProductLoadingIndicator), findsNothing);
    messages.add([]);
    await tester.pumpAndSettle();
    expect(find.text('Пока нет файлов'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
