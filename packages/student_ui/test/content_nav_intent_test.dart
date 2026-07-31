import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  group('ContentNavResolver structured action', () {
    test('app_screen maps known screens', () {
      expect(
        ContentNavResolver.resolveAction(
            {'kind': 'app_screen', 'screen_key': 'home'}),
        isA<ContentNavAppTab>().having((i) => i.tab, 'tab', ContentAppTab.home),
      );
      expect(
        ContentNavResolver.resolveAction(
            {'kind': 'app_screen', 'screen_key': 'diary'}),
        isA<ContentNavDiary>(),
      );
      expect(
        ContentNavResolver.resolveAction(
            {'kind': 'app_screen', 'screen_key': 'help'}),
        isA<ContentNavAppTab>().having((i) => i.tab, 'tab', ContentAppTab.info),
      );
    });

    test('unknown screen / kind → disabled', () {
      expect(
        ContentNavResolver.resolveAction(
            {'kind': 'app_screen', 'screen_key': 'chat'}),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({'kind': 'explode'}),
        isA<ContentNavDisabled>(),
      );
    });

    test('entity targets require uuid', () {
      const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'reference_article',
          'target_id': id,
        }),
        isA<ContentNavReferenceArticle>().having((i) => i.targetId, 'id', id),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'vacancy',
          'target_id': 'not-a-uuid',
        }),
        isA<ContentNavDisabled>(),
      );
    });

    test('external_url https only', () {
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'external_url',
          'url': 'https://example.com/a',
        }),
        isA<ContentNavExternalHttps>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'external_url',
          'url': 'http://example.com/a',
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'external_url',
          'url': 'javascript:alert(1)',
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'external_url',
          'url': '//evil.example',
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'external_url',
          'url': 'https://user:pass@example.com',
        }),
        isA<ContentNavDisabled>(),
      );
    });

    test('structured action present never falls back to legacy', () {
      final intent = ContentNavResolver.resolve(
        action: {'kind': 'app_screen', 'screen_key': 'chat'},
        ctaRoute: '/home',
        ctaUrl: null,
      );
      expect(intent, isA<ContentNavDisabled>());
    });

    test('malformed action sentinel never falls back to legacy', () {
      final intent = ContentNavResolver.resolve(
        action: const {'kind': '__malformed__'},
        ctaRoute: '/home',
        ctaUrl: null,
      );
      expect(intent, isA<ContentNavDisabled>());
    });

    test('unknown action keys are disabled', () {
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'app_screen',
          'screen_key': 'home',
          'extra': 'nope',
        }),
        isA<ContentNavDisabled>(),
      );
    });

    test('wrong-typed or empty present action fields are disabled', () {
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'app_screen',
          'screen_key': 'home',
          'url': 123,
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'none',
          'target_id': false,
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'app_screen',
          'screen_key': 'home',
          'url': null,
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'app_screen',
          'screen_key': '',
        }),
        isA<ContentNavDisabled>(),
      );
    });

    test('HomePromoPayload preserves malformed action over legacy CTA', () {
      final payload = HomePromoPayload.tryParse({
        'title': 'T',
        'subtitle': 'S',
        'icon_key': 'help',
        'cta_label': 'Go',
        'gradient_colors': ['#7367F0', '#B784F7'],
        'dismissible': true,
        'cta_route': '/home',
        'action': 'not-a-map',
      });
      expect(payload, isNotNull);
      expect(
        ContentNavResolver.resolve(
          action: payload!.action,
          ctaRoute: payload.ctaRoute,
          ctaUrl: payload.ctaUrl,
        ),
        isA<ContentNavDisabled>(),
      );
    });

    test('none with extras → disabled', () {
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'none',
          'url': 'https://example.com',
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({'kind': 'none'}),
        isA<ContentNavNone>(),
      );
    });
  });

  group('ContentNavResolver legacy', () {
    test('allowlisted routes', () {
      expect(
        ContentNavResolver.resolveLegacy(ctaRoute: '/my-diary'),
        isA<ContentNavDiary>(),
      );
      expect(
        ContentNavResolver.resolveLegacy(ctaRoute: '/diary'),
        isA<ContentNavDiary>(),
      );
      expect(
        ContentNavResolver.resolveLegacy(ctaRoute: '/help'),
        isA<ContentNavAppTab>().having((i) => i.tab, 'tab', ContentAppTab.info),
      );
      expect(
        ContentNavResolver.resolveLegacy(ctaRoute: '/learning'),
        isA<ContentNavAppTab>()
            .having((i) => i.tab, 'tab', ContentAppTab.learning),
      );
    });

    test('forbidden routes / http', () {
      expect(
        ContentNavResolver.resolveLegacy(ctaRoute: '/chat'),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveLegacy(ctaRoute: '/admin'),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveLegacy(ctaUrl: 'http://example.com'),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveLegacy(
          ctaRoute: '/home',
          ctaUrl: 'https://example.com',
        ),
        isA<ContentNavDisabled>(),
      );
    });
  });
}
