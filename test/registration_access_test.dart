import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/authentication/screens/register_screen.dart';

void main() {
  testWidgets('registration exposes no unsafe provisioning and returns to login', (tester) async {
    var returned = false;
    await tester.pumpWidget(MaterialApp(home: RegisterScreen(toggleView: () { returned = true; })));
    expect(find.byType(TextFormField), findsNothing);
    expect(find.textContaining('Самостоятельная регистрация временно недоступна'), findsOneWidget);
    await tester.tap(find.text('Вернуться ко входу'));
    expect(returned, isTrue);
  });
}
