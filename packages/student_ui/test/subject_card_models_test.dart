import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  test('section_order fail-closed on unknown/dupes; appends omitted', () {
    expect(
      tryNormalizeSubjectCardSectionOrder([
        'how_to_pass',
        'unknown',
      ]),
      isNull,
    );
    expect(
      tryNormalizeSubjectCardSectionOrder([
        'how_to_pass',
        'how_to_pass',
      ]),
      isNull,
    );
    final order = tryNormalizeSubjectCardSectionOrder([
      'how_to_pass',
      'description',
    ]);
    expect(order, isNotNull);
    expect(order!.first, 'how_to_pass');
    expect(order[1], 'description');
    expect(order, containsAll(kSubjectCardSectionAllowlist));
  });

  test('SubjectCardPayload fail-closed and merge fields', () {
    expect(SubjectCardPayload.tryParse({}), isNull);
    final payload = SubjectCardPayload.tryParse({
      'subject_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'canonical_name': 'Базы данных',
      'short_description': 'SQL',
      'description': 'Полное',
      'section_order': ['description', 'short_description'],
      'hours_total': 144,
      'credits': 4,
      'hours_credits_available': true,
      'teachers': [
        {'id': 't1', 'full_name': 'Иванов И.И.'},
        {'full_name': 'без id'},
      ],
      'useful_links': [
        {'title': 'Docs', 'url': 'https://example.com'},
        {'title': 'bad', 'url': 'javascript:alert(1)'},
      ],
    });
    expect(payload, isNotNull);
    expect(payload!.sectionOrder.first, 'description');
    expect(payload.teachers.single.displayName, 'Иванов И.И.');
    expect(payload.usefulLinks.single.url, 'https://example.com');
    expect(payload.hoursCreditsAvailable, isTrue);
    expect(payload.displayAssets.heroImage, isNull);
    expect(payload.displayAssets.attachments, isEmpty);
  });

  test('SubjectCardAsset and assets bundle fail-closed', () {
    expect(
      SubjectCardAsset.tryParse({'id': 'x', 'mime_type': 'image/jpeg'}),
      isNull,
    );
    final asset = SubjectCardAsset.tryParse({
      'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      'title': 'Syllabus',
      'mime_type': 'application/pdf',
      'byte_size': 1200,
      'version_number': 2,
      'asset_kind': 'attachment',
      'logical_asset_id': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    });
    expect(asset, isNotNull);
    expect(asset!.isPdf, isTrue);

    final bundle = SubjectCardAssets.tryParse({
      'catalog': {
        'hero_image': {
          'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          'title': 'Hero',
          'mime_type': 'image/png',
          'byte_size': 500,
          'version_number': 1,
          'asset_kind': 'hero_image',
          'logical_asset_id': 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        },
        'attachments': [],
      },
      'offering': {
        'hero_image': null,
        'attachments': [
          {
            'id': 'dddddddd-dddd-dddd-dddd-dddddddddddd',
            'title': 'Lab',
            'mime_type': 'application/pdf',
            'byte_size': 900,
            'version_number': 1,
            'asset_kind': 'attachment',
            'logical_asset_id': 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
          },
        ],
      },
    });
    expect(bundle, isNotNull);
    expect(bundle!.mergedForDisplay.heroImage?.title, 'Hero');
    expect(bundle.mergedForDisplay.attachments.single.title, 'Lab');

    expect(
      SubjectCardPayload.tryParse({
        'subject_id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        'canonical_name': 'Test',
        'section_order': [],
        'assets': {'attachments': 'not-a-list'},
      }),
      isNull,
    );
  });
}
