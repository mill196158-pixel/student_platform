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
  });
}
