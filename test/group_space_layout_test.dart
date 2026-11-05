import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:student_platform/src/services/file_service.dart';
import 'package:student_platform/src/ui/group_space/data/group_space_repository.dart';
import 'package:student_platform/src/ui/group_space/group_space_screen.dart';
import 'package:student_platform/src/ui/group_space/models/group_space.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Repo extends GroupSpaceRepository {
  _Repo(SupabaseClient client, {this.cancelled = false, this.waitForTopics})
      : super(client: client, fileService: FileService(supabase: client));
  final bool cancelled;
  final Completer<void>? waitForTopics;
  static const _snapshot = GroupSpaceSnapshot(
    groupId: 'g',
    teamId: 't',
    chatId: 'c',
    title: 'Пространство группы',
    isOrganizer: true,
  );

  @override
  Future<GroupSpaceSnapshot?> peekCachedSpace() async =>
      waitForTopics == null ? null : _snapshot;
  @override
  Future<GroupSpaceSnapshot> getMySpace({bool createIfMissing = true}) async {
    expect(createIfMissing, false);
    return _snapshot;
  }

  @override
  Future<List<GroupCollection>> listCollections() async => const [
        GroupCollection(
            id: 'c',
            title: 'Завершённый сбор',
            description: 'Материалы и организационные вопросы',
            purpose: 'Учебные материалы',
            status: 'closed')
      ];
  @override
  Future<List<GroupTopicSelection>> listTopicSelections() async {
    await waitForTopics?.future;
    return [
      GroupTopicSelection(
          id: 's',
          title: 'Выбор темы курсового проекта',
          description: 'Темы для подготовки',
          status: cancelled ? 'cancelled' : 'open',
          allowChange: true)
    ];
  }

  @override
  Future<List<GroupTopicOption>> listTopicOptions(String id) async => [
        GroupTopicOption(
            id: 'o',
            selectionId: id,
            title:
                'Расчёт сети водоснабжения жилого района и выбор оборудования',
            capacity: 2,
            taken: 1,
            sortOrder: 0)
      ];
  @override
  Future<String?> myTopicPick(String id) async => cancelled ? 'o' : null;
  @override
  Future<List<Map<String, dynamic>>> listCollectionContributions(
          String id) async =>
      [
        {
          'user_id': 'u',
          'display_name':
              'Участник с очень длинным именем для проверки переносов',
          'payment_status': 'reported'
        },
      ];
}

void main() {
  testWidgets('cancelled selection retains the option and hides choosing',
      (tester) async {
    final client = SupabaseClient('https://layout.invalid', 'local',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
      fail('Unexpected request: ${request.method}');
    }));
    final waitForTopics = Completer<void>();
    await tester.pumpWidget(MaterialApp(
        home: GroupSpaceScreen(
            repository:
                _Repo(client, cancelled: true, waitForTopics: waitForTopics),
            createIfMissing: false)));
    await tester.pump();
    expect(find.text('Открыть общий чат группы'), findsOneWidget);
    expect(find.text('Выборов темы пока нет'), findsNothing);
    expect(find.byType(ProductLoadingIndicator), findsOneWidget);
    waitForTopics.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбор темы курсового проекта'));
    await tester.pumpAndSettle();
    expect(find.text('Выбор темы курсового проекта'), findsOneWidget);
    expect(find.text('Отменено'), findsOneWidget);
    expect(find.textContaining('Расчёт сети водоснабжения'), findsOneWidget);
    expect(find.text('Ваш выбор · Занято 1 из 2'), findsOneWidget);
    expect(find.text('Выбрать'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
          'group forms and details fit $size dark=$dark without mutation',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var calls = 0;
        final client = SupabaseClient('https://layout.invalid', 'local',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
            httpClient: MockClient((request) async {
          calls++;
          return http.Response('[]', 200, request: request);
        }));
        await tester.pumpWidget(MaterialApp(
            theme: ProductTheme.build(
                brightness: dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(1.5),
                    viewInsets: const EdgeInsets.only(bottom: 160)),
                child: child!),
            home: GroupSpaceScreen(
                repository: _Repo(client), createIfMissing: false)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Создать сбор'));
        await tester.pumpAndSettle();
        expect(find.text('Новый сбор'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        final createTopic = find.byTooltip('Создать выбор темы');
        await tester.scrollUntilVisible(createTopic, 100,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        await tester.tap(createTopic);
        await tester.pumpAndSettle();
        expect(find.text('Мест на тему'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
            find.text('Выбор темы курсового проекта'), 140,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Выбор темы курсового проекта'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(find.text('Добавить тему'), 140,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Добавить тему'));
        await tester.pumpAndSettle();
        expect(find.text('Название темы'), findsOneWidget);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('Завершённый сбор'), -140,
            scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Завершённый сбор'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
            find.text('Участник с очень длинным именем для проверки переносов'),
            140,
            scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
        expect(calls, 0);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
