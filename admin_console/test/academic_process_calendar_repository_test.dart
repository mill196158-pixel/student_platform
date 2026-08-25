import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/academic_process_calendar_models.dart';
import 'package:student_platform_admin/features/import_studio/academic_process_calendar_repository.dart';

class _FakeRpc implements AcademicProcessCalendarRpcClient {
  final List<(String, Map<String, dynamic>?)> calls = [];
  List<Map<String, dynamic>> existingCalendars = [];

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    calls.add((function, params));
    return switch (function) {
      'admin_list_terms' => [
        {
          'id': 'term-1',
          'academic_year_id': 'year-1',
          'year_name': '2026/2027',
        },
        {
          'id': 'term-2',
          'academic_year_id': 'year-1',
          'year_name': '2026/2027',
        },
      ],
      'admin_list_educational_programs' => [
        {
          'id': 'program-1',
          'direction_code': '08.03.01',
          'profile_name': 'ПГС',
          'study_form': 'full_time',
          'status': 'active',
        },
      ],
      'admin_list_curriculum_plans' => [
        {
          'id': 'plan-reviewed',
          'educational_program_id': 'program-1',
          'plan_code': 'ПГС-2025',
          'admission_year': 2025,
          'nominal_semesters': 8,
          'status': 'reviewed',
        },
        {
          'id': 'plan-draft',
          'educational_program_id': 'program-1',
          'plan_code': 'draft',
          'admission_year': 2025,
          'nominal_semesters': 8,
          'status': 'draft',
        },
      ],
      'admin_list_groups' => [
        {'id': 'group-1', 'name': 'СбПГС-2025'},
      ],
      'admin_list_academic_process_calendars' => existingCalendars,
      'admin_upsert_academic_process_calendar' => 'calendar-1',
      'admin_create_academic_process_calendar_version' => 'version-1',
      'admin_academic_process_calendar_dry_run' => {
        'ok': true,
        'apply_enabled': false,
        'publish_enabled': false,
        'summary': {'total': 1, 'new': 1, 'error': 0},
        'items': [
          {
            'row_number': 1,
            'period_key': 'session-1',
            'derived_semester_number': 3,
            'classification': 'new',
            'errors': <String>[],
            'warnings': <String>[],
          },
        ],
      },
      _ => throw StateError('Unexpected RPC $function'),
    };
  }
}

void main() {
  test('loads deduplicated years and only reviewed/active plans', () async {
    final rpc = _FakeRpc();
    final repository = SupabaseAcademicProcessCalendarRepository(
      rpcClient: rpc,
    );

    final references = await repository.loadReferences();

    expect(references.years, hasLength(1));
    expect(references.years.single.label, '2026/2027');
    expect(references.programs.single.label, contains('очная'));
    expect(references.plans.map((item) => item.id), ['plan-reviewed']);
    expect(references.groups.single.label, 'СбПГС-2025');
  });

  test('creates an unverified draft version and sends safe dry-run', () async {
    final rpc = _FakeRpc();
    final repository = SupabaseAcademicProcessCalendarRepository(
      rpcClient: rpc,
    );

    final versionId = await repository.createDraftVersion(
      academicYearId: 'year-1',
      audienceKind: AcademicProcessAudienceKind.plan,
      audienceId: 'plan-reviewed',
      title: 'График 2026/2027',
      versionLabel: 'v1',
      sourceFileName: 'calendar.png',
      sourceMimeType: 'image/png',
      localSha256: List.filled(64, 'A').join(),
    );
    final result = await repository.dryRun(
      versionId: versionId,
      rows: [
        AcademicProcessPeriodDraft(
          periodKey: 'session-1',
          type: AcademicProcessPeriodType.session,
          courseNumber: 2,
          termInYear: 1,
          startsOn: DateTime(2026, 12, 20),
          endsOn: DateTime(2027, 1, 20),
        ),
      ],
    );

    expect(versionId, 'version-1');
    expect(result.ok, isTrue);
    expect(result.applyEnabled, isFalse);
    expect(result.publishEnabled, isFalse);
    expect(result.items.single['derived_semester_number'], 3);

    final createCalendar = rpc.calls.firstWhere(
      (call) => call.$1 == 'admin_upsert_academic_process_calendar',
    );
    expect(createCalendar.$2?['p_curriculum_plan_id'], 'plan-reviewed');
    expect(createCalendar.$2?['p_group_id'], isNull);

    final createVersion = rpc.calls.firstWhere(
      (call) => call.$1 == 'admin_create_academic_process_calendar_version',
    );
    expect(createVersion.$2?['p_source_sha256'], List.filled(64, 'a').join());
    expect(createVersion.$2?.containsKey('p_source_verified'), isFalse);

    final dryRun = rpc.calls.firstWhere(
      (call) => call.$1 == 'admin_academic_process_calendar_dry_run',
    );
    expect(
      dryRun.$2?['p_parser_contract_version'],
      SupabaseAcademicProcessCalendarRepository.parserContract,
    );
    final rows = dryRun.$2?['p_rows'] as List;
    expect((rows.single as Map)['semester_number'], isNull);
    expect((rows.single as Map).containsKey('semester_number'), isFalse);
  });

  test('local dry-run rejects duplicate keys and bad dates', () async {
    final repository = LocalAcademicProcessCalendarRepository();
    final result = await repository.dryRun(
      versionId: 'version',
      rows: [
        AcademicProcessPeriodDraft(
          periodKey: 'same',
          type: AcademicProcessPeriodType.study,
          courseNumber: 1,
          termInYear: 1,
          startsOn: DateTime(2026, 9, 2),
          endsOn: DateTime(2026, 9, 1),
        ),
        AcademicProcessPeriodDraft(
          periodKey: 'same',
          type: AcademicProcessPeriodType.other,
          courseNumber: 1,
          termInYear: 1,
          startsOn: DateTime(2026, 9, 1),
          endsOn: DateTime(2026, 9, 2),
        ),
      ],
    );

    expect(result.ok, isFalse);
    expect(result.errorCount, 2);
    expect(result.items.last['errors'], contains('duplicate_period_key'));
    expect(result.items.last['errors'], contains('other_period_note_required'));
  });

  test('existing calendar title is updated with optimistic version', () async {
    final rpc = _FakeRpc()
      ..existingCalendars = [
        {
          'id': 'calendar-existing',
          'academic_year_id': 'year-1',
          'audience_kind': 'plan',
          'curriculum_plan_id': 'plan-reviewed',
          'title': 'Старое название',
          'row_version': 7,
        },
      ];
    final repository = SupabaseAcademicProcessCalendarRepository(
      rpcClient: rpc,
    );

    await repository.createDraftVersion(
      academicYearId: 'year-1',
      audienceKind: AcademicProcessAudienceKind.plan,
      audienceId: 'plan-reviewed',
      title: 'Новое название',
      versionLabel: 'v2',
    );

    final update = rpc.calls.firstWhere(
      (call) => call.$1 == 'admin_upsert_academic_process_calendar',
    );
    expect(update.$2?['p_id'], 'calendar-existing');
    expect(update.$2?['p_expected_row_version'], 7);
    expect(update.$2?['p_title'], 'Новое название');
  });
}
