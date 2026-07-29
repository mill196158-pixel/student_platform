import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/subject_card_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Hard-error policy for Stage 16.1 subject card loading.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> sampleCard() => {
        'subject_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'subject_offering_id': 'off-1',
        'canonical_name': 'DB',
        'description': 'Cached',
        'section_order': ['description'],
      };

  test('hard non-transient error rethrows (no silent cache return)', () async {
    SharedPreferences.setMockInitialValues({});
    await SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async => sampleCard(),
    ).loadForOffering('off-1');
    expect(
      await SubjectCardService(currentUserId: () => 'user-1').loadCached('off-1'),
      isNotNull,
    );

    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        throw StateError('hard failure');
      },
    );
    expect(() => service.loadForOffering('off-1'), throwsA(isA<StateError>()));
    // Cache remains on disk; UI bootstrap must replace paint with unavailable.
    expect(await service.loadCached('off-1'), isNotNull);
  });

  test('hard Postgrest non-transient without cache rethrows', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SubjectCardService(
      currentUserId: () => 'user-1',
      rpc: (function, {params}) async {
        throw const PostgrestException(
          message: 'syntax error',
          code: '42601',
        );
      },
    );
    expect(
      () => service.loadForOffering('off-1'),
      throwsA(isA<PostgrestException>()),
    );
    expect(await service.loadCached('off-1'), isNull);
  });
}
