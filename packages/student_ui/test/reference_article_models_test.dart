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

    test('v3 parses heading/info/warning/list blocks', () {
      final raw = validV2Payload()
        ..['blocks'] = [
          {'type': 'heading', 'text': 'Section', 'level': 2},
          {'type': 'info', 'text': 'Useful tip'},
          {'type': 'warning', 'text': 'Be careful'},
          {
            'type': 'list',
            'style': 'bullet',
            'items': ['One', 'Two'],
          },
          {
            'type': 'list',
            'style': 'numbered',
            'items': ['First', 'Second'],
          },
          {'type': 'text', 'text': 'Body'},
        ];
      final payload = ReferenceArticlePayload.tryParseV3(raw);
      expect(payload?.blocks, hasLength(6));
      expect(payload!.blocks[0], isA<ReferenceHeadingBlock>());
      expect((payload.blocks[0] as ReferenceHeadingBlock).level, 2);
      expect(payload.blocks[1], isA<ReferenceInfoBlock>());
      expect(payload.blocks[2], isA<ReferenceWarningBlock>());
      expect(payload.blocks[3], isA<ReferenceListBlock>());
      expect((payload.blocks[3] as ReferenceListBlock).style, 'bullet');
      expect((payload.blocks[4] as ReferenceListBlock).isNumbered, isTrue);
      expect(
        ReferenceArticlePayload.tryParseForSchema(3, raw)?.blocks,
        hasLength(6),
      );
    });

    test('v3 heading defaults level to 1', () {
      final block = ReferenceBlock.tryParse({
        'type': 'heading',
        'text': 'Title',
      });
      expect(block, isA<ReferenceHeadingBlock>());
      expect((block! as ReferenceHeadingBlock).level, 1);
    });

    test('v3 rejects invalid heading level and empty list', () {
      expect(
        ReferenceBlock.tryParse({
          'type': 'heading',
          'text': 'Title',
          'level': 4,
        }),
        isNull,
      );
      expect(
        ReferenceBlock.tryParse({
          'type': 'list',
          'style': 'bullet',
          'items': <String>[],
        }),
        isNull,
      );
      expect(
        ReferenceBlock.tryParse({
          'type': 'list',
          'style': 'checklist',
          'items': ['A'],
        }),
        isNull,
      );
      expect(
        ReferenceBlock.tryParse({'type': 'info'}),
        isNull,
      );
    });

    test('v3 toWireJson emits new block keys', () {
      final payload = ReferenceArticlePayload(
        iconKey: 'help',
        shortText: 'Summary',
        blocks: const [
          ReferenceHeadingBlock(text: 'H', level: 3),
          ReferenceInfoBlock(text: 'Info'),
          ReferenceWarningBlock(text: 'Warn'),
          ReferenceListBlock(style: 'numbered', items: ['A', 'B']),
        ],
      );
      expect(payload.toWireJson(schemaVersion: 3)['blocks'], [
        {'type': 'heading', 'text': 'H', 'level': 3},
        {'type': 'info', 'text': 'Info'},
        {'type': 'warning', 'text': 'Warn'},
        {
          'type': 'list',
          'style': 'numbered',
          'items': ['A', 'B'],
        },
      ]);
    });

    test('v3 still rejects unknown block type', () {
      final raw = validV2Payload()
        ..['blocks'] = [
          {'type': 'html', 'text': '<b>x</b>'},
        ];
      expect(ReferenceArticlePayload.tryParseV3(raw), isNull);
    });

    test('v3 rejects client category field like v2', () {
      expect(
        ReferenceArticlePayload.tryParseV3(validV1Payload()),
        isNull,
      );
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

    test('parses v3 article row with new blocks', () {
      final article = ManagedReferenceArticle.tryParse(
        sampleArticle(
          schemaVersion: 3,
          payload: validV2Payload()
            ..['blocks'] = [
              {'type': 'heading', 'text': 'How to', 'level': 1},
              {'type': 'info', 'text': 'Tip'},
              {
                'type': 'list',
                'style': 'bullet',
                'items': ['Step'],
              },
            ],
        ),
      );
      expect(article?.schemaVersion, 3);
      expect(article?.payload.blocks, hasLength(3));
    });

    test('rejects unsupported schema version', () {
      final raw = sampleArticle(schemaVersion: 4);
      expect(ManagedReferenceArticle.tryParse(raw), isNull);
    });
  });

  group('StudentReferenceBrowseView', () {
    testWidgets('renders AppBar title and article cards', (tester) async {
      final bundle = ReferenceBundle(
        categories: [ReferenceCategory.tryParse(sampleCategory())!],
        articles: [ManagedReferenceArticle.tryParse(sampleArticle())!],
      );
      ManagedReferenceArticle? tapped;

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 390,
            height: 844,
            child: StudentReferenceBrowseView(
              bundle: bundle,
              selectedArticleId: 'art-1',
              onArticleTap: (article) => tapped = article,
            ),
          ),
        ),
      );

      expect(find.text('Справочник'), findsOneWidget);
      expect(find.text('Article title'), findsOneWidget);
      expect(find.text('Доступы'), findsWidgets);
      expect(find.byType(StudentReferenceArticleCard), findsOneWidget);

      await tester.tap(find.byType(StudentReferenceArticleCard));
      await tester.pump();
      expect(tapped?.id, 'art-1');
    });
  });

  group('StudentReferenceArticleDetail v3 blocks', () {
    testWidgets('renders heading info warning and list', (tester) async {
      final article = ManagedReferenceArticle.tryParse(
        sampleArticle(
          schemaVersion: 3,
          payload: validV2Payload()
            ..['blocks'] = [
              {'type': 'heading', 'text': 'Heading block', 'level': 2},
              {'type': 'info', 'text': 'Info callout'},
              {'type': 'warning', 'text': 'Warning callout'},
              {
                'type': 'list',
                'style': 'bullet',
                'items': ['Bullet one'],
              },
            ],
        ),
      )!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudentReferenceArticleDetail(article: article),
          ),
        ),
      );

      expect(find.text('Heading block'), findsOneWidget);
      expect(find.text('Info callout'), findsOneWidget);
      expect(find.text('Warning callout'), findsOneWidget);
      expect(find.text('Bullet one'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
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
