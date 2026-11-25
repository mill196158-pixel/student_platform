import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('E2E-086 reveal an email and hand one recipient to the composer',
      (tester) async {
    final opened = <Uri>[];
    const address = 'career+summer@example.invalid';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: StudentVacancyDetailSheet(
        card: ManagedVacancyCard(
            id: 'v',
            origin: ContentOrigin.admin,
            payload: VacancyCardPayload.demoVacancies.first,
            hasContacts: true),
        onComposeEmail: (uri) async {
          opened.add(uri);
          return false;
        },
        onRevealContacts: () async => const VacancyContacts(email: address),
      ),
    ))));
    await tester.ensureVisible(find.text('Показать контакты'));
    await tester.tap(find.text('Показать контакты'));
    await tester.pumpAndSettle();
    final button = find.widgetWithText(TextButton, 'Email: $address');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    expect(opened, [Uri(scheme: 'mailto', path: address)]);
    expect(find.text('Не удалось открыть почтовое приложение'), findsOneWidget);
  });
}
