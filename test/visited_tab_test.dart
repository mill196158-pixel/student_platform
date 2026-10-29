import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/navigation/visited_tab.dart';

void main() {
  testWidgets(
      'unvisited tabs defer initialization and retain state after navigation',
      (tester) async {
    var active = false;
    var builds = 0;
    late StateSetter update;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return VisitedTab(
          active: active,
          builder: (_) {
            builds++;
            return const Material(child: TextField());
          });
    })));
    expect(builds, 0);
    update(() {
      active = true;
    });
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'retained note');
    update(() {
      active = false;
    });
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    update(() {
      active = true;
    });
    await tester.pump();
    expect(find.text('retained note'), findsOneWidget);
  });
}
