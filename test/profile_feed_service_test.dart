import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/profile/profile_feed_service.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeRpc implements ProfileFeedRpcClient {
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
    int sortOrder = 0,
  }) {
    return {
      'id': id,
      'template_key': 'profile_feed_card_v1',
      'schema_version': 1,
      'placement': 'profile_feed',
      'sort_order': sortOrder,
      'priority': 0,
      'origin': origin,
      'payload': {
        'title': 'About',
        'subtitle': 'Team',
        'cta_label': 'Open',
        'cta_route': '/schedule',
      },
    };
  }

  test('loads list and caches matched rows in order', () async {
    final rpc = _FakeRpc(
      response: [
        sampleRow(id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', sortOrder: 0),
        sampleRow(id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', sortOrder: 1),
      ],
    );
    final service = ProfileFeedService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.isDemoFallback, isFalse);
    expect(result.cards.length, 2);
    expect(result.cards.first.id, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

    final cached = await service.loadCached();
    expect(cached.cards.length, 2);
    expect(cached.cards.first.payload.title, 'About');
  });

  test('malformed sibling does not hide valid cards', () async {
    final bad = sampleRow()..['template_key'] = 'nope';
    final good = sampleRow(id: '22222222-2222-2222-2222-222222222222');
    final rpc = _FakeRpc(response: [bad, good]);
    final service = ProfileFeedService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.cards.length, 1);
    expect(result.cards.single.id, '22222222-2222-2222-2222-222222222222');
  });

  test('empty list hides feed and does not resurrect demo', () async {
    final rpc = _FakeRpc(response: []);
    final service = ProfileFeedService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.intentionallyEmpty, isTrue);
    expect(result.hideFeed, isTrue);
    expect(result.displayCards, isEmpty);
    expect(result.isDemoFallback, isFalse);
  });

  test('loadError alone does not hide as intentional empty', () {
    const result = ProfileFeedLoadResult(loadError: true);
    expect(result.hideFeed, isFalse);
    expect(result.showLoadError, isTrue);
    expect(result.displayCards, isEmpty);
  });

  test('missing RPC dual-reads to labeled demo', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message:
            'Could not find the function public.get_my_content_for_placement',
        code: 'PGRST202',
      ),
    );
    final service = ProfileFeedService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    final result = await service.load();
    expect(result.rpcUnavailable, isTrue);
    expect(result.isDemoFallback, isTrue);
    expect(result.displayCards.every((c) => c.showDemoBadge), isTrue);
  });

  test('permission errors are not treated as missing RPC', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(
        message: 'permission denied for function get_my_content_for_placement',
        code: '42501',
      ),
    );
    final service = ProfileFeedService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    await expectLater(service.load(), throwsA(isA<PostgrestException>()));
  });

  test('cache keys are user-scoped', () async {
    final rpc = _FakeRpc(response: [sampleRow()]);
    final serviceA = ProfileFeedService(
      rpcClient: rpc,
      currentUserId: () => 'user-a',
    );
    await serviceA.load();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('${ProfileFeedService.keyPrefix}__user-a'), isNotNull);

    final serviceB = ProfileFeedService(
      rpcClient: _FakeRpc(response: []),
      currentUserId: () => 'user-b',
    );
    final forB = await serviceB.loadCached();
    expect(forB.isDemoFallback, isTrue);
  });

  test('clearAll removes profile feed cache keys', () async {
    SharedPreferences.setMockInitialValues({
      '${ProfileFeedService.keyPrefix}__user-a': jsonEncode([sampleRow()]),
      'other_key': 'keep',
    });
    final service = ProfileFeedService(
      rpcClient: _FakeRpc(),
      currentUserId: () => 'user-a',
    );
    await service.clearAll();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('${ProfileFeedService.keyPrefix}__user-a'), isNull);
    expect(prefs.getString('other_key'), 'keep');
  });

  test('recordEvent is nonfatal', () async {
    final rpc = _FakeRpc(
      error: const PostgrestException(message: 'boom', code: 'XX000'),
    );
    final service = ProfileFeedService(rpcClient: rpc);
    await service.recordEvent(
      '11111111-1111-1111-1111-111111111111',
      'impression',
    );
    expect(rpc.calls, contains('record_content_event'));
  });

  test('ProfileFeedPayload / ManagedProfileFeedCard fail-closed', () {
    expect(ProfileFeedPayload.tryParse({'title': 'x'}), isNull);
    expect(
      ManagedProfileFeedCard.tryParse({
        'id': '1',
        'template_key': 'home_promo_v1',
        'schema_version': 1,
        'origin': 'admin',
        'payload': {
          'title': 't',
          'subtitle': 's',
          'cta_label': 'c',
        },
      }),
      isNull,
    );
    expect(
      ManagedProfileFeedCard.tryParse(sampleRow()),
      isNotNull,
    );
  });
}
