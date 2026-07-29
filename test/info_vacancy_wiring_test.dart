import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/data/academic_context_service.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/info/reference_service.dart';
import 'package:student_platform/src/ui/info/vacancy_service.dart';
import 'package:student_platform/src/ui/info/vacancy_submission_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeVacancyRpc implements VacancyRpcClient {
  _FakeVacancyRpc({this.response, this.error});

  dynamic response;
  Object? error;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    if (error != null) throw error!;
    return response;
  }
}

class _MissingReferenceRpc implements ReferenceRpcClient {
  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    throw const PostgrestException(
      message: 'Could not find the function public.get_my_reference_bundle',
      code: 'PGRST202',
    );
  }
}

class _MissingSubmitRpc implements VacancySubmissionRpcClient {
  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    throw const PostgrestException(
      message: 'Could not find the function public.submit_vacancy',
      code: 'PGRST202',
    );
  }
}

VacancySubmissionService _testSubmissionService() {
  return VacancySubmissionService(
    rpcClient: _MissingSubmitRpc(),
    currentUserId: () => 'user-a',
  );
}

ReferenceService _testReferenceService() {
  return ReferenceService(
    rpcClient: _MissingReferenceRpc(),
    currentUserId: () => 'user-a',
  );
}

InfoPlanState _emptyPlan() {
  return InfoPlanState(
    contextData: const AcademicContext(
      userId: 'user-a',
      groupId: 'group-1',
      groupName: 'Test',
      hasActiveEnrollment: true,
    ),
    subjects: const [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    InfoScreen.debugClearMemoryCache();
  });

  Future<void> pumpJobsSection(
    WidgetTester tester, {
    required VacancyService vacancyService,
    VacancySubmissionService? submissionService,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: InfoScreen(
          initialSectionName: 'jobs',
          vacancyService: vacancyService,
          vacancySubmissionService:
              submissionService ?? _testSubmissionService(),
          referenceService: _testReferenceService(),
          debugUserId: 'user-a',
          planLoader: () async => _emptyPlan(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('demo fallback shows labeled StudentVacancyCard list',
      (tester) async {
    final service = VacancyService(
      rpcClient: _FakeVacancyRpc(
        error: const PostgrestException(
          message: 'Could not find the function public.get_my_vacancies',
          code: 'PGRST202',
        ),
      ),
      currentUserId: () => 'user-a',
    );

    await pumpJobsSection(tester, vacancyService: service);
    await tester.pumpAndSettle();

    expect(find.text('Доска вакансий'), findsOneWidget);
    expect(find.byType(StudentVacancyCard), findsNWidgets(3));
    expect(find.text('Пример'), findsNWidgets(3));
    expect(find.text('Junior Flutter Developer'), findsOneWidget);
  });

  testWidgets('successful empty hides vacancy cards without demo resurrection',
      (tester) async {
    final service = VacancyService(
      rpcClient: _FakeVacancyRpc(response: []),
      currentUserId: () => 'user-a',
    );

    await pumpJobsSection(tester, vacancyService: service);
    await tester.pumpAndSettle();

    expect(find.text('Вакансии пока пусты'), findsOneWidget);
    expect(find.byType(StudentVacancyCard), findsNothing);
    expect(find.text('Junior Flutter Developer'), findsNothing);
  });

  testWidgets('managed vacancies render via StudentVacancyCard and filter search',
      (tester) async {
    final service = VacancyService(
      rpcClient: _FakeVacancyRpc(
        response: [
          {
            'id': '11111111-1111-1111-1111-111111111111',
            'title': 'Backend Engineer',
            'company_name': 'Tech Co',
            'summary': 'API work',
            'employment_type': 'full_time',
            'work_format': 'remote',
            'origin': 'admin',
            'is_demo': false,
            'has_contacts': true,
          },
          {
            'id': '22222222-2222-2222-2222-222222222222',
            'title': 'Design Intern',
            'company_name': 'Studio',
            'summary': 'UI tasks',
            'employment_type': 'internship',
            'work_format': 'hybrid',
            'origin': 'admin',
            'is_demo': false,
            'has_contacts': false,
          },
        ],
      ),
      currentUserId: () => 'user-a',
    );

    await pumpJobsSection(tester, vacancyService: service);
    await tester.pumpAndSettle();

    expect(find.byType(StudentVacancyCard), findsNWidgets(2));
    expect(find.text('Backend Engineer'), findsOneWidget);
    expect(find.text('Design Intern'), findsOneWidget);
    expect(find.text('Пример'), findsNothing);

    await tester.enterText(find.byType(TextField), 'backend');
    await tester.pump();

    expect(find.text('Backend Engineer'), findsOneWidget);
    expect(find.text('Design Intern'), findsNothing);
    expect(find.text('Результаты поиска'), findsOneWidget);
  });

  testWidgets('jobs hero opens propose vacancy screen', (tester) async {
    final service = VacancyService(
      rpcClient: _FakeVacancyRpc(
        error: const PostgrestException(
          message: 'Could not find the function public.get_my_vacancies',
          code: 'PGRST202',
        ),
      ),
      currentUserId: () => 'user-a',
    );

    await pumpJobsSection(tester, vacancyService: service);
    await tester.pumpAndSettle();

    expect(find.text('Предложить вакансию'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Предложить вакансию'));
    await tester.pumpAndSettle();

    expect(find.text('Название *'), findsOneWidget);
    expect(
      find.textContaining('не публикуется сразу'),
      findsOneWidget,
    );
  });
}
