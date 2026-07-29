import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/subject_card_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> sampleCard() => {
        'subject_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'subject_offering_id': 'off-1',
        'canonical_name': 'DB',
        'description': 'Local override',
        'how_to_pass': 'Tips',
        'section_order': ['description', 'how_to_pass'],
        'hours_total': 108,
        'credits': 3,
        'hours_credits_available': true,
        'teachers': [
          {'id': 't1', 'full_name': 'Ivanov'},
        ],
      };

  test('loads merged payload from get_subject_card', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        expect(function, 'get_subject_card');
        expect(params?['p_subject_offering_id'], 'off-1');
        return sampleCard();
      },
    );
    final result = await service.loadForOffering('off-1');
    expect(result.card, isNotNull);
    expect(result.card!.description, 'Local override');
    expect(result.fromCache, isFalse);
  });

  test('P1 fail-closed: malformed section_order rejects payload', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async => {
            'subject_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
            'canonical_name': 'DB',
            'section_order': ['nope'],
          },
    );
    final result = await service.loadForOffering('off-1');
    expect(result.card, isNull);
  });

  test('missing RPC surfaces PostgrestException including 42883', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        throw const PostgrestException(
          message: 'function public.get_subject_card(uuid) does not exist',
          code: '42883',
        );
      },
    );
    expect(
      () => service.loadForOffering('off-1'),
      throwsA(isA<PostgrestException>()),
    );
    expect(
      SubjectCardService.isMissingRpc(
        const PostgrestException(message: 'x', code: '42883'),
      ),
      isTrue,
    );
  });

  test('P1 cache-first: loadCached available before slow network completes',
      () async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<Map<String, dynamic>>();
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) => gate.future,
    );
    // Seed cache via successful first load.
    final seeder = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async => sampleCard(),
    );
    await seeder.loadForOffering('off-1');

    final cachedBefore = await service.loadCached('off-1');
    expect(cachedBefore, isNotNull);
    expect(cachedBefore!.description, 'Local override');

    final pending = service.loadForOffering('off-1');
    expect(gate.isCompleted, isFalse);
    expect(await service.loadCached('off-1'), isNotNull);
    gate.complete(sampleCard());
    final result = await pending;
    expect(result.card, isNotNull);
    expect(result.fromCache, isFalse);
  });

  test('P1 transient network failure returns last-good cache', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        calls += 1;
        if (calls == 1) return sampleCard();
        throw const PostgrestException(
          message: 'network down',
          code: '57014',
        );
      },
    );
    final first = await service.loadForOffering('off-1');
    expect(first.card, isNotNull);
    final second = await service.loadForOffering('off-1');
    expect(second.fromCache, isTrue);
    expect(second.networkFailed, isTrue);
  });

  test('P1 successful malformed/empty response clears cache fail-closed',
      () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        calls += 1;
        if (calls == 1) return sampleCard();
        return 'not-a-map';
      },
    );
    await service.loadForOffering('off-1');
    expect(await service.loadCached('off-1'), isNotNull);
    final bad = await service.loadForOffering('off-1');
    expect(bad.card, isNull);
    expect(bad.fromCache, isFalse);
    expect(await service.loadCached('off-1'), isNull);
  });

  test('P1 access denied clears cache (42501 / P0002)', () async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        calls += 1;
        if (calls == 1) return sampleCard();
        throw const PostgrestException(
          message: 'forbidden',
          code: '42501',
        );
      },
    );
    await service.loadForOffering('off-1');
    expect(await service.loadCached('off-1'), isNotNull);

    final denied = await service.loadForOffering('off-1');
    expect(denied.accessDenied, isTrue);
    expect(denied.card, isNull);
    expect(await service.loadCached('off-1'), isNull);

    final serviceNotFound = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        throw const PostgrestException(message: 'not_found', code: 'P0002');
      },
    );
    // re-seed
    await SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async => sampleCard(),
    ).loadForOffering('off-1');
    final gone = await serviceNotFound.loadForOffering('off-1');
    expect(gone.accessDenied, isTrue);
    expect(await serviceNotFound.loadCached('off-1'), isNull);
  });

  test('P1 cache is user-scoped and cleared on clearAll', () async {
    SharedPreferences.setMockInitialValues({});
    final a = SubjectCardService(
      currentUserId: () => 'user-a',
      rpc: (function, {params}) async => sampleCard(),
    );
    await a.loadForOffering('off-1');
    final b = SubjectCardService(
      currentUserId: () => 'user-b',
      rpc: (function, {params}) async {
        throw const PostgrestException(message: 'network down', code: '57014');
      },
    );
    expect(() => b.loadForOffering('off-1'), throwsA(isA<PostgrestException>()));
    await a.clearAll();
    expect(await a.loadCached('off-1'), isNull);
  });
}
