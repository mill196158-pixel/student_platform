import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/main.dart' as app;

Future<void> startStudentApp(WidgetTester tester) async {
  var finished = false;
  final startup = app.main().whenComplete(() => finished = true);
  // Android starts with a loader frame before the real app is initialized.
  // IntegrationTestWidgetsFlutterBinding needs the test to pump that frame.
  startup.ignore();
  for (var frame = 0; !finished && frame < 300; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (!finished) fail('Application bootstrap did not finish within 30 seconds');
  await startup;
}
