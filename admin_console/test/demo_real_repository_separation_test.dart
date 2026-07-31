import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/core/auth/admin_backend_config.dart';
import 'package:student_platform_admin/features/content/home_promo/home_promo_repository.dart';
import 'package:student_platform_admin/features/content/home_promo/supabase_home_promo_repository.dart';
import 'package:student_platform_admin/features/content/profile_feed/profile_feed_repository.dart';
import 'package:student_platform_admin/features/content/profile_feed/supabase_profile_feed_repository.dart';
import 'package:student_platform_admin/features/content/reference/reference_repository.dart';
import 'package:student_platform_admin/features/content/shared/admin_content_backend.dart';
import 'package:student_platform_admin/features/content/vacancies/vacancy_repository.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  tearDown(() {
    AdminBackendConfig.debugDemoModeOverride = null;
  });

  test(
    'Local home promo seeds demo legacy key and never uses Supabase class',
    () async {
      final local = LocalHomePromoRepository();
      final items = await local.list();
      expect(items, isNotEmpty);
      expect(
        items.any(
          (e) => e.legacyKey == 'content:home_promo:stuck_with_assignment',
        ),
        isTrue,
      );
      expect(local, isNot(isA<SupabaseHomePromoRepository>()));
    },
  );

  test('Local profile feed seeds three demo legacy keys', () async {
    final local = LocalProfileFeedRepository();
    final items = await local.list();
    final keys = items.map((e) => e.legacyKey).whereType<String>().toSet();
    expect(
      keys.containsAll({
        'content:profile_feed:about',
        'content:profile_feed:schedule',
        'content:profile_feed:discounts',
      }),
      isTrue,
    );
    expect(local, isNot(isA<SupabaseProfileFeedRepository>()));
  });

  test('Local reference seeds demo articles with legacy keys', () async {
    final local = LocalReferenceRepository();
    final articles = await local.listArticles();
    expect(articles.length, greaterThanOrEqualTo(6));
    expect(articles.every((a) => a.origin == ContentOrigin.demo), isTrue);
    expect(
      articles.any(
        (a) => a.legacyKey == 'content:reference_article:login_cabinet',
      ),
      isTrue,
    );
  });

  test('Local vacancies seed three demo drafts with legacy keys', () async {
    final local = LocalVacancyRepository();
    final items = await local.list();
    final demos = items.where((e) => e.origin == ContentOrigin.demo).toList();
    expect(demos.length, greaterThanOrEqualTo(3));
    final keys = demos.map((e) => e.legacyKey).whereType<String>().toSet();
    expect(
      keys.containsAll({
        'vacancy:junior_flutter',
        'vacancy:teaching_assistant',
        'vacancy:presentation_designer',
      }),
      isTrue,
    );
  });

  test('Demo mode flag is explicit bool contract', () {
    expect(AdminBackendConfig.isDemoMode, isA<bool>());
  });

  test('Local home promo list replay does not duplicate legacy key', () async {
    final local = LocalHomePromoRepository();
    final first = await local.list();
    final second = await local.list();
    final firstKeys = first.map((e) => e.legacyKey).whereType<String>().toList()
      ..sort();
    final secondKeys =
        second.map((e) => e.legacyKey).whereType<String>().toList()..sort();
    expect(firstKeys, secondKeys);
    expect(
      firstKeys.where((k) => k == 'content:home_promo:stuck_with_assignment'),
      hasLength(1),
    );
  });

  test('Demo mode resolveRepository returns Local factory result', () {
    final resolved = AdminContentBackend.resolveRepository<String>(
      isDemoMode: true,
      client: null,
      localFactory: () => 'local',
      supabaseFactory: (_) => 'supabase',
    );
    expect(resolved, 'local');
  });

  test('Real mode with null client fail-closes and never returns Local', () {
    var localCalled = false;
    var supabaseCalled = false;
    expect(
      () => AdminContentBackend.resolveRepository<String>(
        isDemoMode: false,
        client: null,
        localFactory: () {
          localCalled = true;
          return 'local';
        },
        supabaseFactory: (_) {
          supabaseCalled = true;
          return 'supabase';
        },
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          AdminContentBackend.realUnavailableMessage,
        ),
      ),
    );
    expect(localCalled, isFalse);
    expect(supabaseCalled, isFalse);
  });
}
