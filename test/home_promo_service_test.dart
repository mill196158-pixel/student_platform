import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRpc implements HomePromoRpcClient {
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
    String origin = 'admin',
    bool dismissible = true,
  }) {
    return {
      'id': '11111111-1111-1111-1111-111111111111',
      'template_key': 'home_promo_v1',
      'schema_version': 1,
      'placement': 'home_promo',
      'sort_order': 0,
      'priority': 0,
      'origin': origin,
      'payload': {
        'title': 'Managed title',
        'subtitle': 'Managed subtitle',
        'icon_key': 'psychology',
        'gradient_colors': ['#FFFBFF', '#F3EEF9'],
        'cta_label': 'Open',
        'cta_route': '/my-diary',
        'dismissible': dismissible,
      },
    };
  }

  test('loads managed promo and writes cache', () async {
    final rpc = _FakeRpc(response: [sampleRow()]);
    final service = HomePromoService(rpcClient: rpc);
    final result = await service.load();
    expect(result.isDemoFallback, isFalse);
    expect(result.card?.homePromo.title, 'Managed title');
    expect(result.showDemoBadge, isFalse);

    final cached = await service.loadCached();
    expect(cached.card?.id, result.card?.id);
  });

  test('dual-reads schema v2 multi-slot promos (wire or stored)', () async {
    final rows = [
      {
        ...sampleRow(),
        'id': '22222222-2222-2222-2222-222222222222',
        'schema_version': 2,
        'sort_order': 0,
        'payload': {
          ...sampleRow()['payload'] as Map,
          'home_slot': 'top',
          'card_variant': 'image_full',
          'title': 'Top card',
        },
      },
      {
        ...sampleRow(),
        'id': '33333333-3333-3333-3333-333333333333',
        'schema_version': 1,
        'sort_order': 1,
        'payload': {
          ...sampleRow()['payload'] as Map,
          'home_slot': 'after_assignments',
          'card_variant': 'compact_icon',
          'title': 'Legacy slot',
        },
      },
    ];
    final rpc = _FakeRpc(response: rows);
    final service = HomePromoService(rpcClient: rpc);
    final result = await service.load();
    expect(result.cards, hasLength(2));
    expect(result.cards.first.homePromo.effectiveHomeSlot, 'top');
    expect(result.cards.first.homePromo.cardVariant, 'image_full');
    expect(result.cards.last.homePromo.cardVariant, 'compact_icon');
  });

  test('empty list hides strip and does not resurrect demo', () async {
    final rpc = _FakeRpc(response: []);
    final service = HomePromoService(rpcClient: rpc);
    final result = await service.load();
    expect(result.isDemoFallback, isFalse);
    expect(result.intentionallyEmpty, isTrue);
    expect(result.hidePromoStrip, isTrue);
    expect(result.card, isNull);
  });

  test('missing RPC dual-reads to demo with rpcUnavailable', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message:
            'Could not find the function public.get_my_content_for_placement',
        code: 'PGRST202',
      ),
    );
    final service = HomePromoService(rpcClient: rpc);
    final result = await service.load();
    expect(result.rpcUnavailable, isTrue);
    expect(result.isDemoFallback, isTrue);
  });

  test('permission errors are not treated as missing RPC', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message: 'permission denied for function get_my_content_for_placement',
        code: '42501',
      ),
    );
    final service = HomePromoService(rpcClient: rpc);
    await expectLater(service.load(), throwsA(isA<PostgrestException>()));
  });

  test('caches the matched parsed row, not a prior malformed row', () async {
    final bad = sampleRow()..['template_key'] = 'nope';
    final good = sampleRow()..['id'] = '22222222-2222-2222-2222-222222222222';
    final rpc = _FakeRpc(response: [bad, good]);
    final service = HomePromoService(rpcClient: rpc);
    final result = await service.load();
    expect(result.card?.id, '22222222-2222-2222-2222-222222222222');
    final cached = await service.loadCached();
    expect(cached.card?.id, '22222222-2222-2222-2222-222222222222');
  });

  test('dismiss calls RPC and clears cache', () async {
    SharedPreferences.setMockInitialValues({
      HomePromoService.cacheKey: jsonEncode(sampleRow()),
    });
    final rpc = _FakeRpc(response: {'ok': true});
    final service = HomePromoService(rpcClient: rpc);
    await service.dismiss('11111111-1111-1111-1111-111111111111');
    expect(rpc.calls, contains('dismiss_content_item'));
    final cached = await service.loadCached();
    expect(cached.isDemoFallback, isTrue);
  });

  test('recordEvent is nonfatal on RPC failure', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(message: 'boom', code: 'XX000'),
    );
    final service = HomePromoService(rpcClient: rpc);
    await service.recordEvent(
      '11111111-1111-1111-1111-111111111111',
      'impression',
    );
    expect(rpc.calls, contains('record_content_event'));
  });
}
