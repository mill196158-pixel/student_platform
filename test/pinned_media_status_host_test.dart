import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/pinned_media_availability.dart';
import 'package:student_platform/src/core/pinned_media_status_host.dart';

void main() {
  testWidgets('document-only screen exposes retry without a picture', (tester) async {
    final owner = Object(); var retries = 0;
    PinnedMediaAvailability.attach(owner, () { retries++; PinnedMediaAvailability.preparing(owner); });
    PinnedMediaAvailability.unavailable(owner);
    await tester.pumpWidget(const MaterialApp(home: PinnedMediaStatusHost(child: Scaffold(body: Text('Документ.pdf')))));
    expect(find.text('Документ.pdf'), findsOneWidget);
    expect(find.text('Вложения временно недоступны'), findsOneWidget);
    await tester.tap(find.text('Повторить')); await tester.pump();
    expect(retries, 1);
    expect(find.text('Вложения временно недоступны'), findsNothing);
    await tester.pumpWidget(const SizedBox()); PinnedMediaAvailability.detach(owner);
  });
}
