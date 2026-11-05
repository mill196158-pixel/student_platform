import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/guest/guest_public_service.dart';
import 'package:student_platform/src/ui/guest/guest_workspace.dart';
import 'package:student_ui/student_ui.dart';

class _GuestNewsService extends GuestPublicService {
  final imageReady = Completer<Uint8List?>();
  final requests = <String>[];
  @override
  Future<List<Map<String, dynamic>>> rpc(String name,
      [Map<String, dynamic> params = const {}]) async {
    requests.add(name);
    if (name != 'get_guest_news') return [];
    return [
      {
        'id': 'one',
        'title': 'Новость с фото',
        'body': 'Полный текст первой новости',
        'variant': 'imageOverlay',
        'image_path': 'public/photo.jpg'
      },
      {
        'id': 'two',
        'title': 'Вторая новость',
        'body': 'Полный текст второй новости',
        'variant': 'gradientText'
      },
    ];
  }

  @override
  Future<Uint8List?> image(Map<String, dynamic> row) {
    requests.add('image:${row['id']}');
    return row['id'] == 'one' ? imageReady.future : Future.value(null);
  }
}

class _ReorderingNewsService extends _GuestNewsService {
  bool reversed = false;

  @override
  Future<List<Map<String, dynamic>>> rpc(String name,
      [Map<String, dynamic> params = const {}]) async {
    final rows = await super.rpc(name, params);
    return name == 'get_guest_news' && reversed ? rows.reversed.toList() : rows;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final brightness in Brightness.values) {
    testWidgets('guest opens and swipes news with delayed cover $brightness',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _GuestNewsService();
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!),
          home: GuestWorkspace(tab: 0, service: service)));
      await tester.pumpAndSettle();
      final card = find.byType(StudentHomeNewsCard).first;
      await tester.ensureVisible(card);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(StudentNewsStorySheet), findsOneWidget);
      expect(find.text('Полный текст первой новости'), findsOneWidget);
      expect(find.text('Что нового'), findsOneWidget);
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');
      service.imageReady.complete(png);
      await tester.pumpAndSettle();
      final sheet = tester
          .widget<StudentNewsStorySheet>(find.byType(StudentNewsStorySheet));
      expect(sheet.news.first.id, 'one');
      expect(
          find.descendant(
              of: find.byType(StudentNewsStorySheet),
              matching: find.byType(Image)),
          findsWidgets);
      await tester.drag(
          find.descendant(
              of: find.byType(StudentNewsStorySheet),
              matching: find.byType(PageView)),
          const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('Полный текст второй новости'), findsOneWidget);
      await tester.tap(find.byTooltip('Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byType(StudentNewsStorySheet), findsNothing);
      expect(service.requests.where((x) => x.startsWith('get_guest_')).toSet(),
          {'get_guest_news'});
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('late image failure after reader closes is contained',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = _GuestNewsService();
    await tester.pumpWidget(
        MaterialApp(home: GuestWorkspace(tab: 0, service: service)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(StudentHomeNewsCard).first);
    await tester.tap(find.byType(StudentHomeNewsCard).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    service.imageReady.completeError(StateError('offline'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(StudentNewsStorySheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('guest opens the selected second story', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = _GuestNewsService();
    await tester.pumpWidget(
        MaterialApp(home: GuestWorkspace(tab: 0, service: service)));
    await tester.pumpAndSettle();
    final second = find.byType(StudentHomeNewsCard).at(1);
    await tester.ensureVisible(second);
    await tester.tap(second);
    await tester.pumpAndSettle();
    expect(find.text('Полный текст второй новости'), findsOneWidget);
    expect(find.text('Полный текст первой новости'), findsNothing);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    service.imageReady.complete(null);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });
  testWidgets('tap retains the rendered item when a refresh reorders the feed',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = _ReorderingNewsService();
    await tester.pumpWidget(
        MaterialApp(home: GuestWorkspace(tab: 0, service: service)));
    await tester.pumpAndSettle();
    final oldHome =
        tester.widget<StudentHomeView>(find.byType(StudentHomeView));
    final oldTap = oldHome.onNewsTap!;
    expect(oldHome.data.news.first.id, 'one');
    service.reversed = true;
    final refresh = oldHome.onRefresh!();
    await tester.pump();
    await tester.pump();
    expect(
        tester
            .widget<StudentHomeView>(find.byType(StudentHomeView))
            .data
            .news
            .first
            .id,
        'two');
    oldTap(0);
    await tester.pumpAndSettle();
    expect(find.text('Полный текст первой новости'), findsOneWidget);
    expect(find.text('Полный текст второй новости'), findsNothing);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    service.imageReady.complete(null);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await refresh;
    expect(tester.takeException(), isNull);
  });
}
