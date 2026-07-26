import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/info/useful_subject.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    InfoScreen.debugClearMemoryCache();
  });

  group('Profile Stage 13.1', () {
    testWidgets('study section has no Текущий семестр card', (tester) async {
      var diaryTaps = 0;
      var mapTaps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                ProfileStudySection(
                  onDiaryTap: () => diaryTaps += 1,
                  onMapTap: () => mapTaps += 1,
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Учёба'), findsOneWidget);
      expect(find.text('Мой дневник'), findsOneWidget);
      expect(find.text('Карта СПБГАСУ'), findsOneWidget);
      expect(find.text('Текущий семестр'), findsNothing);
      expect(find.text('Зачёты, экзамены и учебный план'), findsNothing);

      await tester.tap(find.text('Мой дневник'));
      await tester.pump();
      expect(diaryTaps, 1);

      await tester.tap(find.text('Карта СПБГАСУ'));
      await tester.pump();
      expect(mapTaps, 1);
    });

    testWidgets('ProfileStudySection builds without errors', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ProfileStudySection(
              onDiaryTap: _noop,
              onMapTap: _noop,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(ProfileStudySection), findsOneWidget);
    });
  });

  group('Info study-plan path remains', () {
    testWidgets('Info still lists subjects and opens semester picker',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: InfoScreen(
            debugUserId: 'user-profile-13-1',
            planLoader: () async => InfoPlanState(
              contextData: const AcademicContext(
                userId: 'user-profile-13-1',
                groupId: 'group-1',
                groupName: 'ВВ-2024',
                recordBookNumber: '123',
                currentSemesterNumber: 4,
                hasActiveEnrollment: true,
              ),
              subjects: const [
                UsefulSubject(
                  id: 'off-1',
                  title: 'Алгебра',
                  subjectId: 'sub-1',
                  groupId: 'group-1',
                  semesterNumber: 3,
                  controlForm: 'Экзамен',
                  description: '',
                  teacherName: '',
                  teamName: '',
                  teamIcon: '',
                  teamGroupName: '',
                  avgDifficultyGlobal: 4.0,
                ),
                UsefulSubject(
                  id: 'off-2',
                  title: 'История',
                  subjectId: 'sub-2',
                  groupId: 'group-1',
                  semesterNumber: 4,
                  controlForm: 'Зачёт',
                  description: '',
                  teacherName: '',
                  teamName: '',
                  teamIcon: '',
                  teamGroupName: '',
                  avgDifficultyGlobal: 3.5,
                ),
              ],
            ),
          ),
        ),
      );
      // Resolve the planLoader future without pumpAndSettle (Info has ongoing frames).
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.text('История'), findsOneWidget);
      expect(find.text('Изменить'), findsOneWidget);
      expect(find.text('Алгебра'), findsNothing);

      await tester.tap(find.text('Изменить'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Past and current semesters remain reachable from Info (not only /exams).
      expect(find.text('Предметы семестра'), findsOneWidget);
      expect(find.text('Семестр 3'), findsOneWidget);
      expect(find.text('Семестр 4'), findsOneWidget);
      expect(find.text('текущий'), findsOneWidget);
    });
  });
}

void _noop() {}
