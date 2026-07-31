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

    test('chat target modes', () {
      const chatId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'chat',
          'target_mode': 'chat_id',
          'target_id': chatId,
        }),
        isA<ContentNavChat>()
            .having((i) => i.targetMode, 'mode', 'chat_id')
            .having((i) => i.targetId, 'id', chatId),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'chat',
          'target_mode': 'current_group_chat',
        }),
        isA<ContentNavChat>().having(
          (i) => i.targetMode,
          'mode',
          'current_group_chat',
        ),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'chat',
          'target_mode': 'current_group_chat',
          'target_id': chatId,
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({
          'kind': 'chat',
          'target_mode': 'chat_id',
          'target_id': 'not-a-uuid',
        }),
        isA<ContentNavDisabled>(),
      );
      expect(
        ContentNavResolver.resolveAction({'kind': 'chat'}),
        isA<ContentNavDisabled>(),
      );
    });

    test('shared HTTPS corpus', () {
      // ignore: avoid_relative_lib_imports
      final corpus = _loadCorpus();
      for (final entry in corpus) {
        final uri = ContentNavResolver.tryParseSafeHttpsUri(entry.url);
        if (entry.accept) {
          expect(uri, isNotNull, reason: entry.url);
        } else {
          expect(uri, isNull, reason: entry.url);
        }
      }
      expect(
        ContentNavResolver.tryParseSafeHttpsUri(
          _urlOfLength(2049),
        ),
        isNull,
      );
      expect(
        ContentNavResolver.tryParseSafeHttpsUri(
          _urlOfLength(2048),
        ),
        isNotNull,
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

List<_Corpus> _loadCorpus() {
  return const [
    _Corpus('https://example.com/a', accept: true),
    _Corpus('http://example.com/a'),
    _Corpus('javascript:alert(1)'),
    _Corpus('data:text/plain,hi'),
    _Corpus('file:///etc/passwd'),
    _Corpus('//evil.example'),
    _Corpus('https://user:pass@example.com'),
    _Corpus('https:///path-only'),
  ];
}

class _Corpus {
  const _Corpus(this.url, {this.accept = false});
  final String url;
  final bool accept;
}

String safeHttpsCorpusOverlongUrl(int length) {
  return _urlOfLength(length);
}

String _urlOfLength(int length) {
  const prefix = 'https://example.com/';
  if (length <= prefix.length) return prefix;
  return '$prefix${'a' * (length - prefix.length)}';
}
