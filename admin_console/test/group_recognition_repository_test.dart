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
    return {
      'preview_id': 'preview-1',
      'summary': {'total': 1, 'exact': 0, 'new_candidate': 1, 'blocked': 0},
      'apply_enabled': false,
      'apply_blocker': 'group_recognition_foundation_preview_only',
      'items': [
        {
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
  });
}
