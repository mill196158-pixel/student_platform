import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  Map<String, dynamic> validV2Payload() => {
        'icon_key': 'help',
        'short_text': 'Short summary',
        'blocks': [
          {'type': 'text', 'text': 'Body text'},
        ],
      };

  Map<String, dynamic> validV1Payload() => {
        ...validV2Payload(),
        'category': 'Доступы',
      };

  Map<String, dynamic> sampleCategory() => {
        'id': 'cat-1',
        'key': 'access',
        'title': 'Доступы',
        'icon_key': 'login',
        'sort_order': 0,
        'status': 'published',
      };

  Map<String, dynamic> sampleArticle({
    int schemaVersion = 2,
    Map<String, dynamic>? payload,
    String id = 'art-1',
  }) =>
      {
        'id': id,
        'title': 'Article title',
        'template_key': 'reference_article_v1',
        'schema_version': schemaVersion,
        'origin': 'admin',
        'sort_order': 0,
        'category_id': 'cat-1',
        'category_title': 'Доступы',
        'payload': payload ?? validV2Payload(),
      };

  group('ReferenceCategory', () {
    test('parses valid category', () {
      final category = ReferenceCategory.tryParse(sampleCategory());
      expect(category?.title, 'Доступы');
      expect(category?.iconKey, 'login');
    });

    test('rejects missing title', () {
      final raw = sampleCategory()..remove('title');
      expect(ReferenceCategory.tryParse(raw), isNull);
    });
  });

  group('ReferenceArticlePayload', () {
    test('v2 parses without category field', () {
      final payload = ReferenceArticlePayload.tryParseV2(validV2Payload());
      expect(payload?.shortText, 'Short summary');
      expect(payload?.legacyCategory, isNull);
    });

    test('v2 rejects client category field', () {
      expect(
        ReferenceArticlePayload.tryParseV2(validV1Payload()),
        isNull,
      );
    });

    test('v1 requires category', () {
      expect(
        ReferenceArticlePayload.tryParseV1(validV2Payload()),
        isNull,
      );
      expect(
        ReferenceArticlePayload.tryParseV1(validV1Payload())?.legacyCategory,
        'Доступы',
      );
    });

    test('rejects unknown block type', () {
      final raw = validV2Payload()
        ..['blocks'] = [
          {'type': 'html', 'text': '<b>x</b>'},
        ];
      expect(ReferenceArticlePayload.tryParseV2(raw), isNull);
    });

    test('rejects non-https link', () {
      final raw = validV2Payload()
        ..['blocks'] = [
          {'type': 'link', 'label': 'Site', 'url': 'http://example.com'},
        ];
      expect(ReferenceArticlePayload.tryParseV2(raw), isNull);
    });

    test('parses all block types', () {
      final raw = validV2Payload()
        ..['blocks'] = [
          {'type': 'text', 'text': 'A'},
          {'type': 'image', 'asset_id': 'img-1', 'caption': 'Cap'},
          {'type': 'file', 'asset_id': 'file-1', 'title': 'PDF'},
          {
            'type': 'link',
            'label': 'Site',
            'url': 'https://example.com',
          },
          {
            'type': 'cta',
            'label': 'Open',
            'route': '/help',
          },
        ];
      final payload = ReferenceArticlePayload.tryParseV2(raw);
      expect(payload?.blocks, hasLength(5));
    });

    test('accepts legacy read aliases body and label', () {
      final raw = validV2Payload()
        ..['blocks'] = [
          {'type': 'text', 'body': 'Legacy body'},
          {'type': 'file', 'asset_id': 'file-1', 'label': 'Legacy label'},
        ];
      final payload = ReferenceArticlePayload.tryParseV2(raw);
      expect(payload?.blocks[0], isA<ReferenceTextBlock>());
      expect((payload!.blocks[0] as ReferenceTextBlock).text, 'Legacy body');
      expect((payload.blocks[1] as ReferenceFileBlock).title, 'Legacy label');
    });

    test('toWireJson emits SQL wire keys', () {
      final payload = ReferenceArticlePayload(
        iconKey: 'help',
        shortText: 'Summary',
        blocks: const [
          ReferenceTextBlock(text: 'Paragraph'),
          ReferenceImageBlock(assetId: 'img-1', caption: 'Cap'),
          ReferenceFileBlock(assetId: 'file-1', title: 'Doc'),
          ReferenceLinkBlock(
            label: 'Site',
            url: 'https://example.com',
          ),
          ReferenceCtaBlock(
            cta: ReferenceArticleCta(label: 'Go', route: '/help'),
          ),
        ],
        cta: const ReferenceArticleCta(
          label: 'Top CTA',
          url: 'https://example.com/help',
        ),
      );
      final wire = payload.toWireJson(schemaVersion: 2);
      expect(wire['blocks'], [
        {'type': 'text', 'text': 'Paragraph'},
        {
          'type': 'image',
          'asset_id': 'img-1',
          'caption': 'Cap',
        },
        {
          'type': 'file',
          'asset_id': 'file-1',
          'title': 'Doc',
        },
        {
          'type': 'link',
          'label': 'Site',
          'url': 'https://example.com',
        },
        {
          'type': 'cta',
          'label': 'Go',
          'route': '/help',
        },
      ]);
      expect(wire.containsKey('cta'), isFalse);
      expect(wire['cta_label'], 'Top CTA');
      expect(wire['cta_url'], 'https://example.com/help');
    });

    test('parses flat top-level cta keys', () {
      final raw = validV2Payload()
        ..addAll({
          'cta_label': 'Help',
          'cta_route': '/info',
        });
      final payload = ReferenceArticlePayload.tryParseV2(raw);
      expect(payload?.cta?.label, 'Help');
      expect(payload?.cta?.route, '/info');
    });

    test('parses nested top-level cta object (read alias)', () {
      final raw = validV2Payload()
        ..['cta'] = {
          'label': 'Help',
          'url': 'https://example.com',
        };
      final payload = ReferenceArticlePayload.tryParseV2(raw);
      expect(payload?.cta?.label, 'Help');
      expect(payload?.cta?.url, 'https://example.com');
    });
  });

  group('ManagedReferenceArticle', () {
    test('parses v2 article row', () {
      final article = ManagedReferenceArticle.tryParse(sampleArticle());
      expect(article?.title, 'Article title');
      expect(article?.schemaVersion, 2);
    });

    test('rejects wrong template', () {
      final raw = sampleArticle()..['template_key'] = 'home_promo_v1';
      expect(ManagedReferenceArticle.tryParse(raw), isNull);
    });

    test('rejects unsupported schema version', () {
      final raw = sampleArticle(schemaVersion: 3);
      expect(ManagedReferenceArticle.tryParse(raw), isNull);
    });
  });

  group('StudentReferenceArticleDetail media callbacks', () {
    testWidgets('invokes onOpenAsset for image and file blocks',
        (tester) async {
      final opened = <String>[];
      final article = ManagedReferenceArticle.tryParse(
        sampleArticle(
          payload: validV2Payload()
            ..['blocks'] = [
              {
                'type': 'image',
                'asset_id': 'img-1',
                'caption': 'Campus map',
              },
              {
                'type': 'file',
                'asset_id': 'file-1',
                'title': 'Guide PDF',
              },
              {
                'type': 'link',
                'label': 'Site',
                'url': 'https://example.com',
              },
            ],
        ),
      )!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudentReferenceArticleDetail(
              article: article,
              onOpenAsset: opened.add,
              onOpenUrl: (_) {},
            ),
          ),
        ),
      );

      await tester.tap(find.text('Campus map'));
      await tester.pump();
      await tester.tap(find.text('Guide PDF'));
      await tester.pump();

      expect(opened, ['img-1', 'file-1']);
    });
  });

  group('ReferenceBundle', () {
    test('parses categories and articles', () {
      final bundle = ReferenceBundle.tryParse({
        'categories': [sampleCategory()],
        'articles': [sampleArticle()],
      });
      expect(bundle?.categories, hasLength(1));
      expect(bundle?.articles, hasLength(1));
    });

    test('skips malformed article siblings', () {
      final raw = {
        'categories': [sampleCategory()],
        'articles': [
          sampleArticle()..['category_id'] = null,
          sampleArticle(id: 'art-2'),
        ],
      };
      final bundle = ReferenceBundle.tryParse(raw);
      expect(bundle, isNotNull);
      expect(bundle!.articles, hasLength(1));
      expect(bundle.articles.first.id, 'art-2');
    });

    test('demo legacy help has labeled demo articles', () {
      final demo = ReferenceBundle.demoLegacyHelp();
      expect(demo.articles, hasLength(6));
      expect(demo.articles.every((a) => a.showDemoBadge), isTrue);
      expect(demo.categories, isNotEmpty);
    });
  });
}
