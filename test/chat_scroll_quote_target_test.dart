import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/tabs/chat/scroll_controller.dart';

void main() {
  testWidgets('reveals a distant quote in a lazy reversed history by id',
      (tester) async {
    final scroll = ScrollController();
    final chat = ChatScrollController(scroll, {});
    final ids = List.generate(120, (i) => 'id-$i');
    await tester.pumpWidget(MaterialApp(
      home: ListView.builder(
        controller: scroll,
        reverse: true,
        scrollCacheExtent: const ScrollCacheExtent.pixels(100),
        itemCount: ids.length,
        itemBuilder: (_, i) {
          final id = ids[ids.length - 1 - i];
          return SizedBox(
            key: chat.keyFor(id),
            height: i < 75 ? 42 : 130,
            child: Text(id),
          );
        },
      ),
    ));
    expect(chat.atBottom(), isTrue);
    expect(chat.messageKeys['id-20']?.currentContext, isNull);
    final reveal = chat.scrollToMessage('id-20', orderedIds: ids);
    await tester.pumpAndSettle();
    await reveal;
    expect(find.text('id-20').hitTestable(), findsOneWidget);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(chat.atBottom(), isFalse);
    expect(chat.nearBottom(), isFalse);
    final offset = scroll.offset;
    await chat.scrollToMessage('id-115', orderedIds: ids, isCurrent: () => false);
    expect(scroll.offset, offset);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });
}
