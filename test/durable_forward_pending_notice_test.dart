import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/forward/durable_forward_pending_notice.dart';

void main() {
  for (final upload in [true, false]) {
    testWidgets('unknown ${upload ? 'upload' : 'send'} explains saved state',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: DurableForwardPendingNotice(upload: upload))));
      expect(find.textContaining('Пересылка сохранена'), findsOneWidget);
      expect(find.textContaining('автоматически не выполняется'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });
  }
}
