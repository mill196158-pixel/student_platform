import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/info/info_subjects_cache.dart';
import 'package:student_platform/src/ui/info/subject_difficulty.dart';
import 'package:student_platform/src/ui/info/subject_info_screen.dart';
import 'package:student_platform/src/ui/info/useful_subject.dart';
import 'package:student_platform/src/ui/info/useful_subjects_repository.dart';

UsefulSubject _subject({
  required String id,
  required String title,
  int? semesterNumber = 4,
  double global = 0,
  double local = 0,
  int votesGlobal = 0,
  int votesLocal = 0,
  String controlForm = 'Экзамен',
}) {
  return UsefulSubject(
    id: id,
    title: title,
    subjectId: 'sub-$id',
    groupId: 'group-1',
    semesterNumber: semesterNumber,
    controlForm: controlForm,
    description: '',
    teacherName: '',
    teamId: null,
    teamName: '',
    teamIcon: '',
    teamGroupName: '',
    chatId: null,
    avgDifficultyGlobal: global,
    avgDifficultyLocal: local,
    votesCountGlobal: votesGlobal,
    votesCountLocal: votesLocal,
  );
}

Map<String, dynamic> _rpcRow({
  required String id,
  required String title,
  int semester = 4,
  double? global,
  double? local,
  int votesGlobal = 0,
  int votesLocal = 0,
}) {
  return {
    'subject_offering_id': id,
    'subject_id': 'sub-$id',
    'group_id': 'group-1',
    'semester_number': semester,
    'subject_title': title,
    'control_form': 'Экзамен',
    'short_description': 'desc',
    'local_description': '',
    'avg_difficulty_global': global,
    'avg_difficulty_local': local,
    'votes_count_global': votesGlobal,
    'votes_count_local': votesLocal,
    'team_id': 'team-$id',
    'chat_id': 'chat-$id',
    'can_vote': true,
    'can_open_chat': true,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    InfoScreen.debugClearMemoryCache();
    InfoSubjectsCache.takePendingVote();
  });

  group('SubjectDifficultySummary', () {
    test('global is preferred over local', () {
      const summary = SubjectDifficultySummary(
        avgDifficultyGlobal: 4.2,
        avgDifficultyLocal: 1.5,
      );
      expect(summary.effectiveDifficulty, 4.2);
      expect(summary.displayLabel, '4.2 / 5');
    });

    test('local is used when global is missing or zero', () {
      const missingGlobal = SubjectDifficultySummary(
        avgDifficultyGlobal: 0,
        avgDifficultyLocal: 3.7,
      );
      expect(missingGlobal.effectiveDifficulty, 3.7);
      expect(missingGlobal.displayLabel, '3.7 / 5');
    });

    test('no ratings → null / Пока нет оценок, never 0 / 5', () {
      const summary = SubjectDifficultySummary(
        avgDifficultyGlobal: 0,
        avgDifficultyLocal: 0,
      );
      expect(summary.effectiveDifficulty, isNull);
      expect(summary.displayLabel, 'Пока нет оценок');
      expect(summary.displayLabel, isNot(contains('0 / 5')));
    });

    test('rounding is display-only', () {
      const summary = SubjectDifficultySummary(
        avgDifficultyGlobal: 4.16,
        avgDifficultyLocal: 0,
      );
      expect(summary.effectiveDifficulty, 4.16);
      expect(summary.displayLabel, '4.2 / 5');
    });
  });

  group('SessionDifficultySummary', () {
    test('[4.0, 5.0, 3.0] → 4.0 with coverage 3 of 5', () {
      final summary = SessionDifficultySummary.fromSubjects(
        currentSemesterNumber: 4,
        subjects: [
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary(
              avgDifficultyGlobal: 4.0,
              avgDifficultyLocal: 0,
            ),
          ),
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary(
              avgDifficultyGlobal: 5.0,
              avgDifficultyLocal: 0,
            ),
          ),
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary(
              avgDifficultyGlobal: 3.0,
              avgDifficultyLocal: 0,
            ),
          ),
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary.empty(),
          ),
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary.empty(),
          ),
        ],
      );

      expect(summary.average, 4.0);
      expect(summary.ratedCount, 3);
      expect(summary.totalCount, 5);
      expect(summary.valueLabel, '4.0 / 5');
      expect(summary.coverageLabel, 'Оценено 3 из 5 предметов');
    });

    test('subjects without ratings are excluded from average', () {
      final summary = SessionDifficultySummary.fromSubjects(
        currentSemesterNumber: 4,
        subjects: [
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary(
              avgDifficultyGlobal: 5.0,
              avgDifficultyLocal: 0,
            ),
          ),
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary.empty(),
          ),
        ],
      );
      expect(summary.average, 5.0);
      expect(summary.ratedCount, 1);
      expect(summary.totalCount, 2);
    });

    test('only current semester is included', () {
      final summary = SessionDifficultySummary.fromSubjects(
        currentSemesterNumber: 4,
        subjects: [
          (
            semesterNumber: 3,
            difficulty: const SubjectDifficultySummary(
              avgDifficultyGlobal: 1.0,
              avgDifficultyLocal: 0,
            ),
          ),
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary(
              avgDifficultyGlobal: 4.0,
              avgDifficultyLocal: 0,
            ),
          ),
          (
            semesterNumber: 5,
            difficulty: const SubjectDifficultySummary(
              avgDifficultyGlobal: 5.0,
              avgDifficultyLocal: 0,
            ),
          ),
        ],
      );
      expect(summary.average, 4.0);
      expect(summary.ratedCount, 1);
      expect(summary.totalCount, 1);
    });

    test('no rated subjects → null / empty copy', () {
      final summary = SessionDifficultySummary.fromSubjects(
        currentSemesterNumber: 4,
        subjects: [
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary.empty(),
          ),
          (
            semesterNumber: 4,
            difficulty: const SubjectDifficultySummary.empty(),
          ),
        ],
      );
      expect(summary.average, isNull);
      expect(summary.valueLabel, 'Пока нет оценок');
      expect(
        summary.coverageLabel,
        'Оценки появятся после первых голосов',
      );
    });

    test('rounds display to one decimal', () {
      final summary = SessionDifficultySummary.compute(
        currentSemesterNumber: 4,
        currentSemesterDifficulties: const [
          SubjectDifficultySummary(
            avgDifficultyGlobal: 4.0,
            avgDifficultyLocal: 0,
          ),
          SubjectDifficultySummary(
            avgDifficultyGlobal: 4.3,
            avgDifficultyLocal: 0,
          ),
        ],
        currentSemesterSubjectCount: 2,
      );
      expect(summary.average, closeTo(4.15, 1e-9));
      expect(summary.valueLabel, '4.2 / 5');
    });
  });

  group('UsefulSubject mapper / cache', () {
    test('rpc row maps into UsefulSubject with difficulty fields', () {
      final subject = UsefulSubject.fromRpcMap(
        _rpcRow(
          id: 'off-1',
          title: 'Алгебра',
          global: 4.25,
          local: 2.0,
          votesGlobal: 10,
          votesLocal: 3,
        ),
      );

      expect(subject.id, 'off-1');
      expect(subject.title, 'Алгебра');
      expect(subject.avgDifficultyGlobal, 4.25);
      expect(subject.avgDifficultyLocal, 2.0);
      expect(subject.votesCountGlobal, 10);
      expect(subject.votesCountLocal, 3);
      expect(subject.difficulty.effectiveDifficulty, 4.25);
      expect(subject.teamId, 'team-off-1');
      expect(subject.chatId, 'chat-off-1');
    });

    test('difficulty and vote counts survive JSON cache round-trip', () {
      final original = _subject(
        id: 'off-2',
        title: 'История',
        global: 3.5,
        local: 4.0,
        votesGlobal: 8,
        votesLocal: 2,
      );
      final restored = UsefulSubject.fromJson(original.toJson());
      expect(restored.avgDifficultyGlobal, 3.5);
      expect(restored.avgDifficultyLocal, 4.0);
      expect(restored.votesCountGlobal, 8);
      expect(restored.votesCountLocal, 2);
      expect(restored.difficulty.displayLabel, '3.5 / 5');
    });

    test('legacy JSON without difficulty fields does not become 0 / 5', () {
      final restored = UsefulSubject.fromJson({
        'id': 'legacy',
        'title': 'Legacy',
        'controlForm': 'Зачёт',
        'description': '',
        'teacherName': '',
        'teamName': '',
        'teamIcon': '',
        'teamGroupName': '',
      });
      expect(restored.avgDifficultyGlobal, 0);
      expect(restored.avgDifficultyLocal, 0);
      expect(restored.difficulty.effectiveDifficulty, isNull);
      expect(restored.difficulty.displayLabel, 'Пока нет оценок');
      expect(restored.difficulty.displayLabel, isNot(contains('0 / 5')));
    });
  });

  group('UsefulSubjectsRepository', () {
    test('N subjects → exactly one rpc_get_my_subjects_v2 call', () async {
      const n = 12;
      final rows = List.generate(
        n,
        (i) => _rpcRow(id: 'off-$i', title: 'Subject $i', global: 3.0 + i / 10),
      );
      final repo = UsefulSubjectsRepository(
        rpcLoader: () async => rows,
        fallbackLoader: (_) async => throw StateError('fallback must not run'),
      );

      final subjects = await repo.load(groupId: 'group-1');
      expect(subjects, hasLength(n));
      expect(repo.rpcCallCount, 1);
      expect(repo.fallbackCallCount, 0);
    });

    test('server request count does not grow with N', () async {
      Future<List<UsefulSubject>> loadN(int n) {
        final repo = UsefulSubjectsRepository(
          rpcLoader: () async => List.generate(
            n,
            (i) => _rpcRow(id: 'off-$i', title: 'S$i', global: 4),
          ),
        );
        return repo.load(groupId: 'g').then((value) {
          expect(repo.rpcCallCount, 1);
          return value;
        });
      }

      final small = await loadN(3);
      final large = await loadN(30);
      expect(small, hasLength(3));
      expect(large, hasLength(30));
    });

    test('rpc failure falls back once, still bounded', () async {
      final repo = UsefulSubjectsRepository(
        rpcLoader: () async => throw Exception('network'),
        fallbackLoader: (groupId) async {
          expect(groupId, 'group-1');
          return [
            {
              'id': 'fb-1',
              'subject_id': 'sub-1',
              'group_id': 'group-1',
              'display_name': 'Fallback',
              'semester_number': 4,
              'curriculum_subjects': {
                'display_name': 'Fallback',
                'control_form': 'Зачёт',
              },
              'subject_catalog': {'canonical_name': 'Fallback'},
            },
          ];
        },
      );

      final subjects = await repo.load(groupId: 'group-1');
      expect(subjects, hasLength(1));
      expect(repo.rpcCallCount, 1);
      expect(repo.fallbackCallCount, 1);
      expect(subjects.single.difficulty.displayLabel, 'Пока нет оценок');
    });

    test('rpc+fallback failure is not masked as empty list', () async {
      final repo = UsefulSubjectsRepository(
        rpcLoader: () async => throw Exception('rpc down'),
        fallbackLoader: (_) async => throw Exception('fallback down'),
      );

      await expectLater(
        repo.load(groupId: 'group-1'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Info UI', () {
    testWidgets('context strip has group/record book/session difficulty',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InfoAcademicContextStrip(
              contextData: const AcademicContext(
                groupName: 'ВВ-2024',
                recordBookNumber: '12345',
                currentSemesterNumber: 4,
                hasActiveEnrollment: true,
              ),
              sessionDifficulty: const SessionDifficultySummary(
                average: 4.1,
                ratedCount: 3,
                totalCount: 5,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Учебный профиль'), findsNothing);
      expect(find.text('Группа'), findsOneWidget);
      expect(find.text('ВВ-2024'), findsOneWidget);
      expect(find.text('№ зачётки'), findsOneWidget);
      expect(find.text('12345'), findsOneWidget);
      expect(find.text('Сложность сессии'), findsOneWidget);
      expect(find.text('4.1 / 5'), findsOneWidget);
      expect(find.textContaining('Оценено'), findsNothing);
      expect(find.textContaining('Оценки появятся'), findsNothing);
    });

    testWidgets('subject card shows difficulty and not Учебный план',
        (tester) async {
      final rated = _subject(id: '1', title: 'Алгебра', global: 4.2);
      final unrated = _subject(id: '2', title: 'История');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                InfoSubjectCard(item: rated),
                InfoSubjectCard(item: unrated),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Учебный план'), findsNothing);
      expect(find.text('Сложность: 4.2 / 5'), findsOneWidget);
      expect(find.text('Пока нет оценок'), findsOneWidget);
      expect(find.textContaining('0 / 5'), findsNothing);
    });

    test('default card navigation target is SubjectInfoScreen', () {
      final subject = _subject(id: 'off-9', title: 'Физика', global: 3.0);
      final screen = subjectInfoScreenFor(subject);
      expect(screen, isA<SubjectInfoScreen>());
      expect(screen.subjectOfferingId, 'off-9');
      expect(screen.title, 'Физика');
      expect(screen.subjectId, 'sub-off-9');
      expect(screen.groupId, 'group-1');
      expect(screen.semesterNumber, 4);
    });

    testWidgets('tap on subject card invokes open callback with subject',
        (tester) async {
      UsefulSubject? opened;
      final subject = _subject(id: 'off-3', title: 'Химия', global: 5.0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InfoSubjectCard(
              item: subject,
              onOpen: (value) => opened = value,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Химия'));
      await tester.pump();
      expect(opened?.id, 'off-3');
      expect(find.byType(SubjectInfoScreen), findsNothing);
    });

    testWidgets('vote invalidation applies optimistic difficulty on Info',
        (tester) async {
      var calls = 0;
      final initial = InfoPlanState(
        contextData: const AcademicContext(
          userId: 'user-1',
          groupId: 'group-1',
          groupName: 'ВВ-2024',
          recordBookNumber: '999',
          currentSemesterNumber: 4,
          hasActiveEnrollment: true,
        ),
        subjects: [
          _subject(id: 'off-vote', title: 'Алгебра'),
        ],
      );
      final afterVote = InfoPlanState(
        contextData: initial.contextData,
        subjects: [
          _subject(id: 'off-vote', title: 'Алгебра', global: 4.0),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: InfoScreen(
            debugUserId: 'user-1',
            planLoader: () async {
              calls += 1;
              return calls <= 1 ? initial : afterVote;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Пока нет оценок'), findsWidgets);

      InfoSubjectsCache.stageVoteUpdate(
        const InfoSubjectVoteUpdate(
          subjectOfferingId: 'off-vote',
          effectiveDifficulty: 4.0,
        ),
      );
      await InfoSubjectsCache.invalidate(userId: 'user-1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('Сложность: 4.0 / 5'), findsOneWidget);
      expect(find.text('Учебный план'), findsNothing);
      expect(calls, greaterThanOrEqualTo(2));
    });

    testWidgets('background refresh error keeps last-good cache on screen',
        (tester) async {
      var failRefresh = false;
      var calls = 0;
      final cached = InfoPlanState(
        contextData: const AcademicContext(
          userId: 'user-1',
          groupId: 'group-1',
          groupName: 'ВВ-2024',
          recordBookNumber: '999',
          currentSemesterNumber: 4,
          hasActiveEnrollment: true,
        ),
        subjects: [
          _subject(id: 'cached', title: 'Кэшированный предмет', global: 4.0),
        ],
      );

      Widget buildScreen({required Key key}) {
        return MaterialApp(
          home: InfoScreen(
            key: key,
            debugUserId: 'user-1',
            planLoader: () async {
              calls += 1;
              if (failRefresh) throw Exception('refresh failed');
              return cached;
            },
          ),
        );
      }

      // Seed last-good cache.
      await tester.pumpWidget(buildScreen(key: const ValueKey('seed')));
      await tester.pumpAndSettle();
      expect(find.text('Кэшированный предмет'), findsOneWidget);
      expect(calls, 1);

      // Force a new State so initState peeks memory cache and silent-refreshes.
      failRefresh = true;
      await tester.pumpWidget(buildScreen(key: const ValueKey('reopen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('Кэшированный предмет'), findsOneWidget);
      expect(find.text('Сложность сессии'), findsOneWidget);
      expect(calls, greaterThanOrEqualTo(2));
    });
  });
}
