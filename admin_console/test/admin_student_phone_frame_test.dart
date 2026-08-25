import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/shared/widgets/admin_student_phone_frame.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  Widget app({
    required Size size,
    bool showNavigation = false,
    int? navigationIndex,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: AdminStudentPhoneFrame(
              showBottomNavigation: showNavigation,
              navigationIndex: navigationIndex,
              child: Builder(
                builder: (context) {
                  final media = MediaQuery.of(context);
                  final theme = Theme.of(context);
                  return Text(
                    '${media.size.width.toInt()}x'
                    '${media.size.height.toInt()} '
                    '${theme.colorScheme.primary.toARGB32()}',
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('scales without overflow in constrained and large hosts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(app(size: const Size(150, 210)));
    await tester.pump();

    expect(find.byKey(const Key('admin-student-phone-frame')), findsOneWidget);
    expect(find.textContaining('374x828'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(app(size: const Size(900, 1000)));
    await tester.pump();

    final frame = tester.getSize(
      find.byKey(const Key('admin-student-phone-frame')),
    );
    expect(frame, const Size(900, 1000));
    expect(
      find.byKey(const Key('admin-student-phone-system-bar')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses student theme and optional validated navigation', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(size: const Size(430, 880), showNavigation: true, navigationIndex: 4),
    );
    await tester.pump();

    expect(find.byType(StudentBottomNav), findsOneWidget);
    final nav = tester.widget<StudentBottomNav>(find.byType(StudentBottomNav));
    expect(nav.currentIndex, 4);
    expect(nav.items, studentBottomNavItems);
    expect(
      find.textContaining(
        '${studentPlatformLightTheme().colorScheme.primary.toARGB32()}',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('rejects ambiguous navigation contracts', () {
    expect(
      () => AdminStudentPhoneFrame(
        showBottomNavigation: true,
        child: const SizedBox(),
      ),
      throwsAssertionError,
    );
    expect(
      () => AdminStudentPhoneFrame(
        navigationIndex: studentBottomNavItems.length,
        child: const SizedBox(),
      ),
      throwsAssertionError,
    );
  });
}
