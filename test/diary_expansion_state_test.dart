import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/profile/diary_expansion_state.dart';

void main() {
  testWidgets('missing user and corrupt preference fall back safely',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'personal_diary_expansion_v1_a_active': 'invalid',
    });
    Widget screen(String? user) => MaterialApp(home: Scaffold(
      body: DiaryExpansionState(
        key: ValueKey(user), userId: user, section: 'active', initiallyExpanded: true,
        builder: (context, expanded, changed) => ExpansionTile(
          title: const Text('Active'), initiallyExpanded: expanded,
          onExpansionChanged: changed, children: const [Text('Content')],
        ),
      ),
    ));
    await tester.pumpWidget(screen(null));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Active'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getKeys(),
        {'personal_diary_expansion_v1_a_active'});
    await tester.pumpWidget(screen('a'));
    await tester.pumpAndSettle();
    expect(find.text('Content'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('sections restore independently and remain account-specific',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    Widget screen(String user) => MaterialApp(
          home: Scaffold(
            body: Column(children: [
              for (final section in ['active', 'done'])
                DiaryExpansionState(
                  key: ValueKey('$user-$section'),
                  userId: user,
                  section: section,
                  initiallyExpanded: section == 'active',
                  builder: (context, expanded, changed) => ExpansionTile(
                    title: Text(section),
                    initiallyExpanded: expanded,
                    onExpansionChanged: changed,
                    children: [Text('$section content')],
                  ),
                ),
            ]),
          ),
        );

    await tester.pumpWidget(screen('a'));
    await tester.pumpAndSettle();
    expect(find.text('active content'), findsOneWidget);
    expect(find.text('done content'), findsNothing);
    await tester.tap(find.text('active'));
    await tester.tap(find.text('done'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen('a'));
    await tester.pumpAndSettle();
    expect(find.text('active content'), findsNothing);
    expect(find.text('done content'), findsOneWidget);
    await tester.pumpWidget(screen('b'));
    await tester.pumpAndSettle();
    expect(find.text('active content'), findsOneWidget);
    expect(find.text('done content'), findsNothing);
    await tester.pumpWidget(screen('a'));
    await tester.pumpAndSettle();
    expect(find.text('active content'), findsNothing);
    expect(find.text('done content'), findsOneWidget);
  });
}
