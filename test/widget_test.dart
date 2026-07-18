import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/themes/themes.dart';

/// Deterministic smoke test: no Supabase/Firebase/network bootstrap.
void main() {
  testWidgets('AppTheme light MaterialApp smoke', (WidgetTester tester) async {
    final theme = AppTheme.light();

    await tester.pumpWidget(
      MaterialApp(
        theme: theme.data,
        home: const Scaffold(
          body: Center(child: Text('Student Platform')),
        ),
      ),
    );

    expect(find.text('Student Platform'), findsOneWidget);
    expect(theme.mode, ThemeMode.light);
    expect(theme.data.primaryColor, isNotNull);
  });
}
