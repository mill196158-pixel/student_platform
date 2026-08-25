import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/import_studio/group_recognition_repository.dart';

class _RecordingRpcClient implements GroupRecognitionRpcClient {
  final calls = <String>[];
  Map<String, dynamic>? lastParams;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    calls.add(function);
    lastParams = params;
    if (function == 'admin_group_recognition_list_academic_years') {
      return [
        {
          'id': 'year-2026',
          'name': '2026/2027',
          'start_year': 2026,
          'is_current': true,
        },
      ];
    }
    final isApplied = function == 'admin_group_recognition_apply';
    return {
      'preview_id': 'preview-1',
      'payload_hash': 'payload-hash',
      'row_version': function == 'admin_group_recognition_save_decisions'
          ? 2
          : 1,
      'decision_revision':
          function == 'admin_group_recognition_save_decisions' ||
              function == 'admin_group_recognition_apply'
          ? 1
          : 0,
      'decision_hash': 'decision-hash',
      'confirmation_token': 'confirmation-token',
      'summary': {'total': 1, 'exact': 0, 'new_candidate': 1, 'blocked': 0},
      'apply_enabled': function == 'admin_group_recognition_save_decisions',
      'results': isApplied
          ? [
              {
                'action': 'create_group',
                'group_name': '1-СбПГС-2',
                'alias_outcome': 'created',
                'identity_outcome': 'created',
                'profile_outcome': 'created',
                'plan_label': 'ПГС · 8 сем.',
              },
            ]
          : <Map<String, dynamic>>[],
      'items': [
        {
          'row_id': 'row-1',
          'source_row_key': '1',
          'raw_group_name': '1-СбПГС-2',
          'normalized_group_name': '1-сбпгс-2',
          'parallel_number': 1,
          'program_alias_key': 'сбпгс',
          'course_number': 2,
          'derived_admission_year': 2025,
          'classification': 'new_candidate',
          'candidate_group_ids': <String>[],
          'candidate_plan_ids': ['plan-1'],
          'warnings': <String>[],
        },
      ],
    };
  }
}

void main() {
  test('Supabase repository maps years and recognition evidence', () async {
    final rpc = _RecordingRpcClient();
    final repository = SupabaseGroupRecognitionRepository(rpcClient: rpc);

    final years = await repository.listAcademicYears();
    final preview = await repository.startPreview(
      academicYearId: years.single.id,
      rows: [
        {'source_row_key': '1', 'group_name': '1-СбПГС-2'},
      ],
      fileName: 'groups.xlsx',
      idempotencyKey: 'batch-1',
    );

    expect(years.single.startYear, 2026);
    expect(years.single.isCurrent, isTrue);
    expect(preview.applyEnabled, isFalse);
    expect(preview.items.single.parallelNumber, 1);
    expect(preview.items.single.courseNumber, 2);
    expect(preview.items.single.derivedAdmissionYear, 2025);
    expect(preview.items.single.programAliasKey, 'сбпгс');
    expect(preview.items.single.candidatePlanIds, ['plan-1']);
    expect(rpc.calls, [
      'admin_group_recognition_list_academic_years',
      'admin_group_recognition_start_preview',
    ]);
    expect(rpc.lastParams?['p_academic_year_id'], 'year-2026');
    expect(rpc.lastParams?['p_idempotency_key'], 'batch-1');

    final saved = await repository.saveDecisions(
      preview: preview,
      decisions: const [
        GroupRecognitionDecision(
          previewRowId: 'row-1',
          action: GroupRecognitionDecisionAction.createGroup,
          selectedPlanId: 'plan-1',
        ),
      ],
    );
    expect(saved.decisionRevision, 1);
    expect(saved.applyEnabled, isTrue);
    expect(rpc.lastParams?['p_expected_payload_hash'], 'payload-hash');

    final applied = await repository.apply(preview: saved);
    expect(applied.results.single.groupName, '1-СбПГС-2');
    expect(rpc.lastParams?['p_confirmation'], 'confirmation-token');
  });

  test('local parser treats right suffix as course', () async {
    const repository = LocalGroupRecognitionRepository(startYear: 2026);
    final preview = await repository.startPreview(
      academicYearId: 'local-2026',
      rows: [
        {'group_name': '1-сб(ПГС)-2'},
        {'group_name': '2-СДПГС-1'},
        {'group_name': 'bad group'},
        {'group_name': '3-Сб/ПГС-2'},
        {'group_name': '3-Сб.ПГС-2'},
        {'group_name': '3-Сб(ПГС-2'},
      ],
      fileName: 'local.csv',
    );

    expect(preview.items[0].parallelNumber, 1);
    expect(preview.items[0].programAliasKey, 'сбпгс');
    expect(preview.items[0].courseNumber, 2);
    expect(preview.items[0].derivedAdmissionYear, 2025);
    expect(preview.items[1].parallelNumber, 2);
    expect(preview.items[1].courseNumber, 1);
    expect(preview.items[1].derivedAdmissionYear, 2026);
    expect(preview.items[2].classification, 'parser_blocked');
    expect(preview.items[3].classification, 'parser_blocked');
    expect(preview.items[4].classification, 'parser_blocked');
    expect(preview.items[5].classification, 'parser_blocked');
    await expectLater(
      () => repository.apply(preview: preview),
      throwsA(
        isA<GroupRecognitionException>().having(
          (error) => error.code,
          'code',
          'local_apply_disabled',
        ),
      ),
    );
  });
}
