import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/guest/guest_workspace.dart';
import 'package:student_platform/src/ui/guest/guest_public_service.dart';
import 'package:student_platform/src/core/password_policy.dart';
import 'package:student_ui/student_ui.dart';

class FakeGuestService extends GuestPublicService {
  final calls = <String>[];
  bool fail = false;
  final first = Completer<Uint8List?>();
  @override
  Future<List<Map<String, dynamic>>> rpc(String name,
      [Map<String, dynamic> params = const {}]) async {
    calls.add(name);
    if (fail) throw StateError('offline');
    if (name == 'get_guest_news')
      return [
        for (final id in ['a', 'b'])
          {
            'id': id,
            'title': 'News $id',
            'body': 'Body',
            'variant': 'gradientText'
          }
      ];
    if (name == 'get_guest_groups')
      return [
        {'id': 'test-group', 'name': 'Тестовая группа'},
        {'id': 'other-group', 'name': 'Другая группа'},
      ];
    if (name == 'get_guest_base') return [];
    if (name == 'get_guest_group_subjects') {
      final id = params['p_group'];
      return [
        {'id': id, 'title': id == 'test-group' ? 'Алгебра' : 'Геодезия'}
      ];
    }
    return [
      {
        'id': 'lesson',
        'date': params['p_from'],
        'subject': 'Математика',
        'time_start': '09:00:00',
        'time_end': '10:30:00',
        'room': '101'
      }
    ];
  }

  @override
  Future<Uint8List?> image(Map<String, dynamic> row) => row['id'] == 'a'
      ? first.future
      : Future.value(Uint8List.fromList([1, 2, 3]));
}

class RefreshGuestService extends GuestPublicService {
  int revision = 0;
  final oldImage = Completer<Uint8List?>();
  @override
  Future<List<Map<String, dynamic>>> rpc(String name,
          [Map<String, dynamic> params = const {}]) async =>
      [
        {
          'id': 'same',
          'title': 'Revision ${++revision}',
          'body': '',
          'variant': 'gradientText',
          'version_number': revision
        }
      ];
  @override
  Future<Uint8List?> image(Map<String, dynamic> row) =>
      row['version_number'] == 1
          ? oldImage.future
          : Future.value(Uint8List.fromList([2]));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'guest tabs preserve original surfaces, remove private extras, select and restore group',
      (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(
        {'user': 'private cache', 'guest_workspace_v1': 'old data'});
    Future<void> open(int tab) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData.dark(),
          home: GuestWorkspace(tab: tab, service: FakeGuestService())));
      await tester.pumpAndSettle();
    }

    await open(4);
    expect(find.text('Мой дневник'), findsNothing);
    expect(find.text('Избранное'), findsNothing);
    expect(find.text('На этом устройстве'), findsNothing);
    expect(find.byType(CircleAvatar), findsWidgets);
    expect(find.text('Твоё место в группе'), findsNothing);
    expect(find.text('Карта СПБГАСУ'), findsOneWidget);
    await open(2);
    expect(find.text('Войти или зарегистрироваться'), findsOneWidget);
    await open(1);
    expect(find.byTooltip('В избранное'), findsNothing);
    await open(3);
    await tester.tap(find.text('Выбрать группу'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тестовая группа'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('guest_selected_group_v1'), contains('test-group'));
    expect(prefs.getString('user'), 'private cache');
    expect(prefs.getString('guest_workspace_v1'), 'old data');
    await open(3);
    expect(find.text('Тестовая группа'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Base group choice scopes subjects and shares it with schedule',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = FakeGuestService();
    var tab = 1;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(home: StatefulBuilder(builder: (_, setState) {
        update = setState;
        return GuestWorkspace(tab: tab, service: service);
      })),
    );
    await tester.pumpAndSettle();

    expect(service.calls, isNot(contains('get_guest_group_subjects')));
    await tester.tap(find.text('Выбрать группу'));
    await tester.pumpAndSettle();
    final groupSearch = find.widgetWithText(TextField, 'Найти группу');
    await tester.enterText(groupSearch, 'нет такой');
    await tester.pumpAndSettle();
    expect(find.text('Группы не найдены'), findsOneWidget);
    await tester.enterText(groupSearch, 'ТЕСТОВАЯ-группа');
    await tester.pumpAndSettle();
    expect(find.text('Другая группа'), findsNothing);
    await tester.tap(find.text('Тестовая группа'));
    await tester.pumpAndSettle();
    expect(find.text('Алгебра'), findsOneWidget);
    expect(find.text('Геодезия'), findsNothing);

    await tester.tap(find.text('Тестовая группа'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Другая группа'));
    await tester.pumpAndSettle();
    expect(find.text('Алгебра'), findsNothing);
    expect(find.text('Геодезия'), findsOneWidget);

    update(() => tab = 3);
    await tester.pumpAndSettle();
    expect(find.text('Другая группа'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('guest_selected_group_v1'), contains('other-group'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('later news cover paints without waiting for first image',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = FakeGuestService();
    await tester.pumpWidget(
        MaterialApp(home: GuestWorkspace(tab: 0, service: service)));
    await tester.pumpAndSettle();
    final view = tester.widget<StudentHomeView>(find.byType(StudentHomeView));
    expect(view.data.news[0].imageBytes, isNull);
    expect(view.data.news[1].imageBytes, isNotNull);
    service.first.complete(Uint8List.fromList([4, 5]));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<StudentHomeView>(find.byType(StudentHomeView))
            .data
            .news[0]
            .imageBytes,
        isNotNull);
  });
  testWidgets('old cover cannot overwrite a refreshed version', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = RefreshGuestService();
    await tester.pumpWidget(
        MaterialApp(home: GuestWorkspace(tab: 0, service: service)));
    await tester.pumpAndSettle();
    await tester
        .widget<StudentHomeView>(find.byType(StudentHomeView))
        .onRefresh!();
    await tester.pumpAndSettle();
    service.oldImage.complete(Uint8List.fromList([1]));
    await tester.pumpAndSettle();
    final news = tester
        .widget<StudentHomeView>(find.byType(StudentHomeView))
        .data
        .news
        .single;
    expect(news.title, 'Revision 2');
    expect(news.imageBytes, Uint8List.fromList([2]));
  });
  test('guest bypasses profile policy, private routes remain protected',
      () async {
    var calls = 0;
    Future<bool> policy() async {
      calls++;
      return true;
    }

    expect(
        await authRouteRedirect(
            path: '/guest', hasSession: false, passwordChangeRequired: policy),
        isNull);
    expect(
        await authRouteRedirect(
            path: '/my-diary',
            hasSession: false,
            passwordChangeRequired: policy),
        '/login');
    expect(calls, 0);
  });
}
