import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/ui/group_space/models/group_space.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/info/subject_difficulty.dart';

void main() {
  group('GroupSpaceSnapshot', () {
    test('parses ensure_group_space payload', () {
      final space = GroupSpaceSnapshot.fromJson({
        'group_id': 'g1',
        'team_id': 't1',
        'chat_id': 'c1',
        'title': 'Пространство группы',
        'is_organizer': true,
      });
      expect(space.exists, isTrue);
      expect(space.isOrganizer, isTrue);
      expect(space.chatId, 'c1');
    });

    test('missing ids mean space does not exist', () {
      final space = GroupSpaceSnapshot.fromJson({
        'group_id': 'g1',
        'team_id': null,
        'chat_id': '',
        'title': null,
        'is_organizer': false,
      });
      expect(space.exists, isFalse);
    });
  });

  group('GroupTopicOption', () {
    test('freeSlots never goes negative', () {
      final option = GroupTopicOption.fromJson({
        'id': 'o1',
        'selection_id': 's1',
        'title': 'Тема A',
        'capacity': 2,
        'taken': 5,
        'sort_order': 0,
      });
      expect(option.freeSlots, 0);
      expect(option.isFull, isTrue);
    });
  });

  testWidgets('Info strip shows group space entry when group is present',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InfoAcademicContextStrip(
            contextData: const AcademicContext(
              groupName: '1-См(ВВ)-2',
              recordBookNumber: '123',
              currentSemesterNumber: 2,
              hasActiveEnrollment: true,
            ),
            sessionDifficulty: const SessionDifficultySummary.empty(),
            onOpenGroupSpace: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('open-group-space')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-group-space')));
    expect(opened, isTrue);
  });

  test('collection contribution proof metadata is preserved in map shape', () {
    final row = <String, dynamic>{
      'user_id': 'u1',
      'participation_status': 'joining',
      'payment_status': 'pending_review',
      'proof_file_id': 'f1',
      'proof_file_name': 'receipt.png',
      'proof_file_url': 'https://example.test/receipt.png',
    };
    expect(row['proof_file_url'], contains('receipt.png'));
    expect(row['payment_status'], 'pending_review');
  });

  test('topic option capacity math supports multi-option selections', () {
    final a = GroupTopicOption.fromJson({
      'id': 'a',
      'selection_id': 's',
      'title': 'Тема 1',
      'capacity': 2,
      'taken': 1,
      'sort_order': 0,
    });
    final b = GroupTopicOption.fromJson({
      'id': 'b',
      'selection_id': 's',
      'title': 'Тема 2',
      'capacity': 2,
      'taken': 2,
      'sort_order': 1,
    });
    expect(a.freeSlots, 1);
    expect(b.isFull, isTrue);
  });
}
