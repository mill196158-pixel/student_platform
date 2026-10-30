import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/data/personal_diary_service.dart';
import 'package:student_platform/src/ui/profile/personal_diary_screen.dart';

class ControlledDiary extends PersonalDiaryService {
  ControlledDiary()
      : super(
            client: SupabaseClient('http://localhost:54321', 'test',
                authOptions: const AuthClientOptions(autoRefreshToken: false)));
  final mutation = Completer<void>();
  final refresh = Completer<PersonalDiaryData>();
  int writes = 0;
  late final task = PersonalDiaryTask(
      id: 'fixture',
      subjectTitle: '',
      title: 'Test task',
      status: 'todo',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026));
  late final data = PersonalDiaryData(
      academicContext: const AcademicContext.empty(),
      availableSemesters: const [],
      selectedSemesterNumber: null,
      allSubjects: const [],
      subjects: const [],
      latestEntries: const [],
      personalTasks: [task],
      upcomingPersonalTasks: [task],
      totalEntries: 0,
      totalFiles: 0);
  @override
  PersonalDiaryData? peekCached({int? semesterNumber}) => null;
  @override
  Future<PersonalDiaryData?> loadCached({int? semesterNumber}) async => data;
  @override
  Future<PersonalDiaryData> loadAndCache({int? semesterNumber}) =>
      refresh.future;
  @override
  Future<void> updatePersonalTaskStatus(
      {required String taskId, required String status}) {
    writes++;
    return mutation.future;
  }
}

void main() {
  for (final fail in [false, true]) {
    testWidgets('status stays visible, blocks duplicate writes, failure=$fail',
        (t) async {
      final service = ControlledDiary();
      await t
          .pumpWidget(MaterialApp(home: PersonalDiaryScreen(service: service)));
      await t.pump();
      await t.pump();
      expect(find.text('Test task'), findsOneWidget);
      await t.ensureVisible(find.text('Статус'));
      await t.tap(find.text('Статус'));
      await t.pump();
      await t.tap(find.text('Статус'));
      await t.pump();
      expect(service.writes, 1);
      expect(find.text('В работе'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      if (fail) {
        service.mutation.completeError(StateError('offline'));
      } else {
        service.mutation.complete();
      }
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Test task'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(fail ? 'Нужно сделать' : 'В работе'), findsOneWidget);
      if (fail)
        expect(find.text('Не удалось сохранить статус. Повторите.'),
            findsOneWidget);
      service.refresh.complete(service.data);
      await t.pump();
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // A fresh canonical response supersedes the optimistic value.
      expect(find.text('Нужно сделать'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
