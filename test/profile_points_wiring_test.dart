import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/profile/student_points_service.dart';
import 'package:student_ui/student_ui.dart';

/// Minimal widget harness mirroring profile points chip wiring.
class _PointsPreview extends StatelessWidget {
  const _PointsPreview({required this.points});

  final StudentPointsLoadResult points;

  @override
  Widget build(BuildContext context) {
    if (points.hidePoints && !points.showLoadError) {
      return const SizedBox.shrink();
    }
    if (points.showLoadError) {
      return const Text('Баллы временно недоступны');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        StudentPointsSummaryChip(
          summary: points.displaySummary,
          showDemoBadge: points.isDemoFallback && points.rpcUnavailable,
        ),
        if (points.displaySummary.entries.isNotEmpty)
          Text(
            'Последнее: ${points.displaySummary.entries.first.signedLabel}',
          ),
      ],
    );
  }
}

void main() {
  testWidgets('shows demo chip with Пример badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _PointsPreview(
            points: const StudentPointsLoadResult(
              isDemoFallback: true,
              rpcUnavailable: true,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('балл.'), findsOneWidget);
    expect(find.text('Пример'), findsOneWidget);
  });

  testWidgets('hides on successful empty balance', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _PointsPreview(
            points: StudentPointsLoadResult(
              summary: const StudentPointsSummary(
                userId: 'user-a',
                balance: 0,
                entries: [],
              ),
              intentionallyEmpty: true,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('балл.'), findsNothing);
    expect(find.text('Пример'), findsNothing);
  });

  testWidgets('shows balance and latest entry line', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _PointsPreview(
            points: StudentPointsLoadResult(
              summary: const StudentPointsSummary(
                userId: 'user-a',
                balance: 3,
                entries: [
                  StudentPointsEntry(
                    delta: 1,
                    reasonCode: PointsReasonCode.reviewApproved,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('3 балл.'), findsOneWidget);
    expect(find.text('Последнее: +1'), findsOneWidget);
  });
}
