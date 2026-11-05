import 'dart:async';

import 'package:flutter/material.dart';
import 'package:student_platform/src/ui/guest/guest_public_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/info/info_screen.dart';
import 'package:student_platform/src/ui/shared/student_section_headers.dart';

class PublicCatalogFake extends GuestPublicService {
  final calls = <String>[];
  bool withJob = false;
  @override
  Future<List<Map<String, dynamic>>> rpc(String name,
      [Map<String, dynamic> params = const {}]) async {
    calls.add(name);
    if (params['p_query'] == 'нет') return [];
    return switch (params['p_section']) {
      'subjects' => [
          {
            'id': 'subject',
            'title': 'Прикладная математика',
            'description': 'Описание из каталога'
          }
        ],
      'help' => [
          {
            'id': 'article',
            'title': 'Как заказать справку',
            'template_key': 'reference_article_v1',
            'schema_version': 3,
            'origin': 'admin',
            'category_id': 'category',
            'category_title': 'Документы',
            'payload': {
              'icon_key': 'description',
              'short_text': 'Справка об обучении',
              'blocks': [
                {'type': 'text', 'text': 'Текст опубликованной статьи'}
              ]
            }
          }
        ],
      _ => withJob
          ? [
              {
                'id': 'job',
                'title': 'Инженер-стажёр',
                'summary': 'Работа с проектами',
                'description': 'Описание вакансии',
                'company_name': 'Компания',
                'origin': 'admin',
                'has_contacts': true
              }
            ]
          : [],
    };
  }
}

class ScopedCatalogFake extends PublicCatalogFake {
  final oldGroup = Completer<List<Map<String, dynamic>>>();
  final requests = <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> rpc(String name,
      [Map<String, dynamic> params = const {}]) async {
    if (name != 'get_guest_group_subjects') return super.rpc(name, params);
    requests.add(params);
    if (params['p_group'] == 'first') return oldGroup.future;
    if (params['p_group'] == 'unavailable') throw StateError('offline');
    return [
      {'id': 'current', 'title': 'Предмет новой группы'}
    ];
  }
}

void main() {
  testWidgets('group switch ignores stale results and never shows all on error',
      (tester) async {
    final service = ScopedCatalogFake();
    var group = 'first';
    late StateSetter update;
    await tester
        .pumpWidget(MaterialApp(home: StatefulBuilder(builder: (_, setState) {
      update = setState;
      return GuestInfoScreen(
        group: (id: group, name: group),
        service: service,
        onAccountInfo: () {},
      );
    })));
    await tester.pumpAndSettle();

    update(() => group = 'second');
    await tester.pumpAndSettle();
    service.oldGroup.complete([
      {'id': 'old', 'title': 'Предмет прежней группы'}
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Предмет новой группы'), findsOneWidget);
    expect(find.text('Предмет прежней группы'), findsNothing);
    expect(service.requests.map((request) => request['p_group']),
        ['first', 'second']);

    update(() => group = 'unavailable');
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить раздел'), findsOneWidget);
    expect(find.text('Прикладная математика'), findsNothing);
    expect(find.text('Предмет новой группы'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'guest Base uses real three-way selector and info opens account explanation',
      (tester) async {
    var accountCalls = 0;
    await tester.pumpWidget(MaterialApp(
        home: GuestInfoScreen(
            service: PublicCatalogFake(),
            onAccountInfo: () => accountCalls++)));
    await tester.pumpAndSettle();
    final header =
        () => tester.widget<StudentInfoHeader>(find.byType(StudentInfoHeader));
    expect(header().subtitle, 'каталог предметов');
    header().onInfoTap();
    expect(accountCalls, 1);
    for (final pair in [
      ('Справочный раздел', 'справочный раздел'),
      ('Вакансии', 'работа и стажировки'),
      ('Предметы', 'каталог предметов')
    ]) {
      header().onSectionTap();
      await tester.pumpAndSettle();
      expect(find.text('Предметы'), findsOneWidget);
      expect(find.text('Справочный раздел'), findsOneWidget);
      expect(find.text('Вакансии'), findsOneWidget);
      await tester.tap(find.text(pair.$1));
      await tester.pumpAndSettle();
      expect(header().subtitle, pair.$2);
      expect(accountCalls, 1);
    }
    expect(find.text('Производная: правило произведения'), findsNothing);
    expect(find.text('Единицы давления'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('guest Base selection survives leaving the tab', (tester) async {
    final bucket = PageStorageBucket();
    var showBase = true;
    late StateSetter update;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return PageStorage(
          bucket: bucket,
          child: showBase
              ? GuestInfoScreen(
                  service: PublicCatalogFake(), onAccountInfo: () {})
              : const SizedBox());
    })));
    tester
        .widget<StudentInfoHeader>(find.byType(StudentInfoHeader))
        .onSectionTap();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Справочный раздел'));
    await tester.pumpAndSettle();
    update(() => showBase = false);
    await tester.pumpAndSettle();
    update(() => showBase = true);
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<StudentInfoHeader>(find.byType(StudentInfoHeader))
            .subtitle,
        'справочный раздел');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'public lists open real details without account, search and empty jobs',
      (tester) async {
    var accountCalls = 0;
    final service = PublicCatalogFake();
    await tester.pumpWidget(MaterialApp(
        home: GuestInfoScreen(
            service: service, onAccountInfo: () => accountCalls++)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Прикладная математика'));
    await tester.pumpAndSettle();
    expect(find.text('Описание из каталога'), findsOneWidget);
    expect(accountCalls, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    tester
        .widget<StudentInfoHeader>(find.byType(StudentInfoHeader))
        .onSectionTap();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Справочный раздел'));
    await tester.pumpAndSettle();
    expect(find.text('Как заказать справку'), findsOneWidget);
    await tester.tap(find.text('Как заказать справку'));
    await tester.pumpAndSettle();
    expect(find.text('Текст опубликованной статьи'), findsOneWidget);
    expect(accountCalls, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'нет');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('По запросу ничего не найдено'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    tester
        .widget<StudentInfoHeader>(find.byType(StudentInfoHeader))
        .onSectionTap();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Вакансии'));
    await tester.pumpAndSettle();
    expect(find.text('Опубликованных вакансий пока нет'), findsOneWidget);
    expect(service.calls.every((n) => n == 'get_guest_base'), isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets('public vacancy opens detail and gates contacts only',
      (tester) async {
    var accountCalls = 0;
    final service = PublicCatalogFake()..withJob = true;
    await tester.pumpWidget(MaterialApp(
        home: GuestInfoScreen(
            service: service, onAccountInfo: () => accountCalls++)));
    await tester.pumpAndSettle();
    tester
        .widget<StudentInfoHeader>(find.byType(StudentInfoHeader))
        .onSectionTap();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Вакансии'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Инженер-стажёр'));
    await tester.pumpAndSettle();
    expect(find.text('Описание вакансии'), findsWidgets);
    expect(find.text('Пожаловаться'), findsNothing);
    expect(find.text('Жалоба отправлена.'), findsNothing);
    expect(accountCalls, 0);
    expect(tester.takeException(), isNull);
  });
}
