import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  testWidgets('renders payload and demo badge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudentVacancyCard(
            payload: VacancyCardPayload.demoVacancies.first,
            showDemoBadge: true,
            expiresLabel: 'Актуально до 30.06.2026',
          ),
        ),
      ),
    );
    expect(find.text('Пример'), findsOneWidget);
    expect(find.text('Junior Flutter Developer'), findsOneWidget);
    expect(find.text('Campus Lab'), findsOneWidget);
    expect(find.text('от 35 000 ₽'), findsOneWidget);
  });

  test('VacancyCardPayload fail-closed rejects missing summary', () {
    expect(
      VacancyCardPayload.tryParse({
        'title': 'Dev',
        'company_name': 'Co',
      }),
      isNull,
    );
  });

  test('ManagedVacancyCard parses get_my_vacancies row', () {
    final card = ManagedVacancyCard.tryParse({
      'id': '11111111-1111-1111-1111-111111111111',
      'title': 'Dev',
      'company_name': 'Co',
      'summary': 'Do things',
      'employment_type': 'internship',
      'work_format': 'remote',
      'origin': 'admin',
      'is_demo': false,
      'has_contacts': true,
    });
    expect(card, isNotNull);
    expect(card!.hasContacts, isTrue);
    expect(card.payload.employmentType, VacancyEmploymentType.internship);
  });

  test('ManagedVacancyCard matchesQuery filters by title and tags', () {
    final card = ManagedVacancyCard.tryParse({
      'id': '11111111-1111-1111-1111-111111111111',
      'title': 'Junior Flutter Developer',
      'company_name': 'Campus Lab',
      'summary': 'Build apps',
      'employment_type': 'internship',
      'work_format': 'hybrid',
      'origin': 'admin',
      'is_demo': false,
    });
    expect(card, isNotNull);
    expect(card!.matchesQuery('flutter'), isTrue);
    expect(card.matchesQuery('campus'), isTrue);
    expect(card.matchesQuery('стажировка'), isTrue);
    expect(card.matchesQuery('missing'), isFalse);
  });

  test('ManagedVacancyCard parses typed assets and description fields', () {
    final card = ManagedVacancyCard.tryParse({
      'id': '11111111-1111-1111-1111-111111111111',
      'title': 'Dev',
      'company_name': 'Co',
      'summary': 'Short',
      'description': 'Full body${vacancyRequirementsMarker}Know Dart',
      'employment_type': 'internship',
      'work_format': 'remote',
      'origin': 'admin',
      'is_demo': false,
      'has_contacts': true,
      'assets': [
        {
          'id': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          'title': 'Job description',
          'mime_type': 'application/pdf',
        },
      ],
      'external_url': 'https://example.com/jobs/1',
    });
    expect(card, isNotNull);
    expect(card!.assets.length, 1);
    expect(card.assets.single.displayLabel, 'Job description');
    expect(card.assets.single.kind, VacancyAssetKind.pdf);
    expect(card.payload.descriptionFull, 'Full body');
    expect(card.payload.requirementsText, 'Know Dart');
    expect(card.payload.externalUrl, 'https://example.com/jobs/1');
    expect(card.payload.hasExternalUrl, isTrue);
  });

  test('VacancyAssetDescriptor uses safe fallback labels', () {
    expect(
      VacancyAssetDescriptor(
        id: 'x',
        title: '',
        mimeType: 'application/pdf',
      ).displayLabel,
      'PDF',
    );
    expect(
      VacancyAssetDescriptor(
        id: 'short',
        title: '',
        mimeType: 'image/png',
      ).displayLabel,
      'Изображение',
    );
    expect(
      VacancyAssetDescriptor(
        id: 'short',
        title: '',
        mimeType: '',
      ).displayLabel,
      'Вложение',
    );
  });

  test('ManagedVacancyCard legacy asset_ids fallback avoids UUID truncation',
      () {
    final card = ManagedVacancyCard.tryParse({
      'id': '11111111-1111-1111-1111-111111111111',
      'title': 'Dev',
      'company_name': 'Co',
      'summary': 'Short',
      'origin': 'admin',
      'is_demo': false,
      'asset_ids': ['abc'],
    });
    expect(card, isNotNull);
    expect(card!.assets.single.displayLabel, 'Вложение');
    expect(card.assets.single.id, 'abc');
  });

  test('ManagedVacancyCard fail-closed on bad origin', () {
    expect(
      ManagedVacancyCard.tryParse({
        'id': '1',
        'title': 'Dev',
        'summary': 'x',
        'origin': 'nope',
      }),
      isNull,
    );
  });

  test('employment and work format labels are Russian', () {
    expect(VacancyEmploymentType.internship.labelRu, 'Стажировка');
    expect(VacancyWorkFormat.remote.labelRu, 'Удалённо');
  });
}
