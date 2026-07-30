import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/profile/student_points_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakePointsRpc implements StudentPointsRpcClient {
  _FakePointsRpc({this.response, this.error});

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

  test('loads get_my_points_summary', () async {
    final rpc = _FakePointsRpc(
      response: {
        'user_id': 'user-a',
        'balance': 3,
        'entries': [
          {'delta': 1, 'reason_code': 'review_approved'},
        ],
      },
    );
    final service = StudentPointsService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.rpcUnavailable, isFalse);
    expect(result.summary?.balance, 3);
    expect(rpc.calls, ['get_my_points_summary']);
  });

  test('missing RPC dual-reads to labeled demo', () async {
    final rpc = _FakePointsRpc(
      error: const PostgrestException(
        message: 'Could not find the function public.get_my_points_summary',
        code: 'PGRST202',
      ),
    );
    final service = StudentPointsService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.rpcUnavailable, isTrue);
    expect(result.isDemoFallback, isTrue);
    expect(result.displaySummary.balance, StudentPointsSummary.demo.balance);
  });

  test('unsigned user returns rpc unavailable demo', () async {
    final rpc = _FakePointsRpc();
    final service = StudentPointsService(
      rpcClient: rpc,
      currentUserId: () => null,
    );
    final result = await service.load();
    expect(result.rpcUnavailable, isTrue);
    expect(rpc.calls, isEmpty);
  });

  test('successful empty balance hides like VacancyService', () async {
    final rpc = _FakePointsRpc(
      response: {
        'user_id': 'user-a',
        'balance': 0,
        'entries': [],
      },
    );
    final service = StudentPointsService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.intentionallyEmpty, isTrue);
    expect(result.hidePoints, isTrue);
  });
}
