import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/vacancy_submission_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeSubmitRpc implements VacancySubmissionRpcClient {
  _FakeSubmitRpc({this.response, this.error});

  dynamic response;
  Object? error;
  final calls = <String>[];
  Map<String, dynamic>? lastParams;

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    calls.add(function);
    lastParams = params;
    if (error != null) throw error!;
    return response;
  }
}

VacancySubmissionDraft _sampleDraft() {
  return const VacancySubmissionDraft(
    title: 'QA Intern',
    companyName: 'Lab',
    summary: 'Manual testing help',
    description: 'Part-time on campus.',
    requirements: 'Attention to detail',
    employmentType: VacancyEmploymentType.internship,
    workFormat: VacancyWorkFormat.hybrid,
    contacts: {'email': 'hr@lab.edu'},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('submit calls submit_vacancy and returns submitted status', () async {
    final rpc = _FakeSubmitRpc(
      response: {
        'ok': true,
        'id': 'vac-1',
        'status': 'submitted',
      },
    );
    final service = VacancySubmissionService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );

    final result = await service.submit(_sampleDraft());

    expect(rpc.calls, ['submit_vacancy']);
    expect(rpc.lastParams?['p_patch'], isA<Map>());
    expect(result.isSubmitted, isTrue);
    expect(result.id, 'vac-1');
    expect(result.isLocalFallback, isFalse);
  });

  test('missing RPC falls back to local submitted storage', () async {
    final rpc = _FakeSubmitRpc(
      error: const PostgrestException(
        message: 'Could not find the function public.submit_vacancy',
        code: 'PGRST202',
      ),
    );
    final service = VacancySubmissionService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );

    final result = await service.submit(_sampleDraft());

    expect(result.isSubmitted, isTrue);
    expect(result.isLocalFallback, isTrue);
    expect(result.rpcUnavailable, isTrue);
    expect(result.status, 'submitted');

    final stored = await service.listLocalSubmissions();
    expect(stored.length, 1);
    expect(stored.first['status'], 'submitted');
    expect(stored.first['title'], 'QA Intern');
  });

  test('draft patch embeds requirements in description', () {
    final patch = _sampleDraft().toSubmitPatch();
    expect(patch['title'], 'QA Intern');
    expect(patch['description'], contains('Требования'));
    expect(patch['description'], contains('Attention to detail'));
    expect(patch['contacts'], {'email': 'hr@lab.edu'});
  });

  test('empty title fails closed without RPC call', () async {
    final rpc = _FakeSubmitRpc(response: {'ok': true});
    final service = VacancySubmissionService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );

    const draft = VacancySubmissionDraft(title: '  ', summary: 'x');
    final result = await service.submit(draft);

    expect(result.ok, isFalse);
    expect(rpc.calls, isEmpty);
  });

  test('local submissions persist per user key', () async {
    SharedPreferences.setMockInitialValues({
      '${VacancySubmissionService.localSubmissionsKey}__user-b':
          jsonEncode([
        {'id': 'old', 'status': 'submitted', 'title': 'Old'},
      ]),
    });
    final rpc = _FakeSubmitRpc(
      error: const PostgrestException(
        message: 'Could not find the function public.submit_vacancy',
        code: 'PGRST202',
      ),
    );
    final service = VacancySubmissionService(
      rpcClient: rpc,
      currentUserId: () => 'user-b',
    );

    await service.submit(_sampleDraft());
    final stored = await service.listLocalSubmissions();
    expect(stored.length, 2);
  });
}
