import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/shared/student_section_headers.dart';

void main() {
  testWidgets(
      'guest Base uses real three-way selector and info opens account explanation',
      (tester) async {
    var accountCalls = 0;
    await tester.pumpWidget(MaterialApp(
        home: GuestInfoScreen(onAccountInfo: () => accountCalls++)));
    await tester.pumpAndSettle();
    final header =
        () => tester.widget<StudentInfoHeader>(find.byType(StudentInfoHeader));
    expect(header().subtitle, 'учебный план');
    header().onInfoTap();
    expect(accountCalls, 1);
    for (final pair in [
      ('Справочный раздел', 'справочный раздел'),
      ('Вакансии', 'работа и стажировки'),
      ('Предметы', 'учебный план')
    ]) {
      header().onSectionTap();
      await tester.pumpAndSettle();
      expect(find.text('Предметы'), findsOneWidget);
      expect(find.text('Справочный раздел'), findsOneWidget);
      expect(find.text('Вакансии'), findsOneWidget);
      await tester.tap(find.text(pair.$1));
      await tester.pumpAndSettle();
      expect(header().subtitle, pair.$2);
      expect(accountCalls, 1);
    }
    expect(find.text('Производная: правило произведения'), findsNothing);
    expect(find.text('Единицы давления'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('guest Base selection survives leaving the tab', (tester) async {
    final bucket = PageStorageBucket();
    var showBase = true;
    late StateSetter update;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return PageStorage(
          bucket: bucket,
          child: showBase
              ? GuestInfoScreen(onAccountInfo: () {})
              : const SizedBox());
    })));
    tester
        .widget<StudentInfoHeader>(find.byType(StudentInfoHeader))
        .onSectionTap();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Справочный раздел'));
    await tester.pumpAndSettle();
    update(() => showBase = false);
    await tester.pumpAndSettle();
    update(() => showBase = true);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<StudentInfoHeader>(find.byType(StudentInfoHeader))
            .subtitle,
        'справочный раздел');
    expect(tester.takeException(), isNull);
  });
}
