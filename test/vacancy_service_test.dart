import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/vacancy_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRpc implements VacancyRpcClient {
  _FakeRpc({this.response, this.error});

  dynamic response;
  Object? error;
  final calls = <String>[];

  @override
  Future<dynamic> rpc(String function, {Map<String, dynamic>? params}) async {
    calls.add(function);
    if (error != null) throw error!;
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> sampleRow({
    String id = '11111111-1111-1111-1111-111111111111',
    String origin = 'admin',
  }) {
    return {
      'id': id,
      'title': 'Dev',
      'company_name': 'Co',
      'summary': 'Build apps',
      'employment_type': 'full_time',
      'work_format': 'hybrid',
      'origin': origin,
      'is_demo': false,
      'has_contacts': false,
    };
  }

  test('loads list and caches matched rows', () async {
    final rpc = _FakeRpc(response: [sampleRow()]);
    final service = VacancyService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.isDemoFallback, isFalse);
    expect(result.cards.length, 1);
    expect(result.cards.first.payload.title, 'Dev');

    final cached = await service.loadCached();
    expect(cached.cards.length, 1);
  });

  test('empty list persists sentinel and loadCached stays intentionally empty',
      () async {
    final rpc = _FakeRpc(response: []);
    final service = VacancyService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.intentionallyEmpty, isTrue);

    final cached = await service.loadCached();
    expect(cached.intentionallyEmpty, isTrue);
    expect(cached.hideVacancies, isTrue);
    expect(cached.isDemoFallback, isFalse);
    expect(cached.displayCards, isEmpty);
  });

  test('empty list is intentionally empty not demo', () async {
    final rpc = _FakeRpc(response: []);
    final service = VacancyService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.intentionallyEmpty, isTrue);
    expect(result.hideVacancies, isTrue);
    expect(result.displayCards, isEmpty);
    expect(result.isDemoFallback, isFalse);
  });

  test('missing RPC dual-reads to labeled demo', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message: 'Could not find the function public.get_my_vacancies',
        code: 'PGRST202',
      ),
    );
    final service = VacancyService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.rpcUnavailable, isTrue);
    expect(result.isDemoFallback, isTrue);
    expect(result.displayCards.every((c) => c.showDemoBadge), isTrue);
    expect(result.displayCards.length, VacancyCardPayload.demoVacancies.length);
  });

  test('permission errors are not treated as missing RPC', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message: 'permission denied for function get_my_vacancies',
        code: '42501',
      ),
    );
    final service = VacancyService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    await expectLater(service.load(), throwsA(isA<PostgrestException>()));
  });

  test('malformed sibling does not hide valid cards', () async {
    final bad = sampleRow()..['title'] = ' ';
    final good = sampleRow(id: '22222222-2222-2222-2222-222222222222');
    final rpc = _FakeRpc(response: [bad, good]);
    final service = VacancyService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.cards.length, 1);
    expect(result.cards.single.id, '22222222-2222-2222-2222-222222222222');
  });

  test('clearAll removes vacancy cache keys', () async {
    SharedPreferences.setMockInitialValues({
      '${VacancyService.keyPrefix}__user-a': jsonEncode([sampleRow()]),
      'other_key': 'keep',
    });
    final service = VacancyService(
      rpcClient: _FakeRpc(),
      currentUserId: () => 'user-a',
    );
    await service.clearAll();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('${VacancyService.keyPrefix}__user-a'), isNull);
    expect(prefs.getString('other_key'), 'keep');
  });
}
