import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/schedule/diary_entry_details_screen.dart';
import 'package:student_platform/src/ui/schedule/subject_diary/subject_diary.dart';
import 'package:student_platform/src/ui/schedule/subject_diary_screen.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Socket implements WebSocketChannel {
  final _incoming = StreamController<dynamic>();
  @override
  Stream<dynamic> get stream => _incoming.stream;
  @override
  final WebSocketSink sink = _Sink();
  @override
  Future<void> get ready async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Sink implements WebSocketSink {
  @override
  void add(dynamic data) {}
  @override
  Future<void> close([int? code, String? reason]) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Repo implements SubjectDiaryRepository {
  bool fail = false;
  Completer<List<SubjectDiaryEntry>>? pending;
  int writes = 0;
  @override
  Future<List<SubjectDiaryEntry>> listByArgs(SubjectDiaryArgs args) async {
    if (pending != null) return pending!.future;
    if (fail) throw StateError('local read failure');
    return [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    writes++;
    return super.noSuchMethod(invocation);
  }
}

void main() {
  late SubjectDiaryRepository original;
  final day = DateTime(2026, 10, 31);
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'https://layout.invalid',
        publishableKey: 'layout-only',
        realtimeClientOptions:
            RealtimeClientOptions(transport: (_, __) => _Socket()),
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async => http.Response('[]', 200,
            request: request, headers: {'content-type': 'application/json'})));
    original = SubjectDiaryRepository.instance;
  });
  tearDownAll(() async {
    SubjectDiaryRepository.instance = original;
    await Supabase.instance.dispose();
  });
  Widget app(Widget home, bool dark, {double inset = 0}) => MaterialApp(
      theme: ProductTheme.build(
          brightness: dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(1.5),
              viewInsets: EdgeInsets.only(bottom: inset)),
          child: child!),
      home: home);
  testWidgets(
      'subject diary retries a failed read and distinguishes no matches',
      (tester) async {
    final repo = _Repo()..fail = true;
    SubjectDiaryRepository.instance = repo;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        app(SubjectDiaryScreen(subjectKey: 'Предмет'), false, inset: 240));
    await tester.pumpAndSettle();
    expect(find.text('Не удалось загрузить дневник предмета'), findsOneWidget);
    expect(tester.takeException(), isNull);
    repo.fail = false;
    await tester.ensureVisible(find.text('Повторить'));
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    final entries = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(find.text('Записей пока нет.'), 100,
        scrollable: entries);
    expect(find.text('Записей пока нет.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'нет совпадений');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
        find.text('По запросу ничего не найдено.'), 100,
        scrollable: entries);
    expect(find.text('По запросу ничего не найдено.'), findsOneWidget);
    expect(repo.writes, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await Supabase.instance.client.realtime.removeAllChannels();
    await Supabase.instance.client.realtime.disconnect();
    Supabase.instance.client.realtime.heartbeatTimer?.cancel();
  });
  for (final size in [
    const Size(320, 568),
    const Size(834, 1112),
    const Size(1440, 900)
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
          'diary note/photo/details fit $size dark=$dark without writes',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = _Repo();
        SubjectDiaryRepository.instance = repo;
        await tester.pumpWidget(app(
            SubjectQuickNoteScreen(
                subjectKey: 'Длинное название предмета', date: day),
            dark,
            inset: 240));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Добавить'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Заметка по предмету'));
        await tester.tap(find.text('Заметка по предмету'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byType(TextField), 'Черновик без сохранения');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Отмена'));
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await tester.pumpWidget(app(
            SubjectPhotoConspectScreen(subjectKey: 'Пример', date: day), dark));
        await tester.pumpAndSettle();
        final save = find.widgetWithText(FilledButton, 'Сохранить конспект');
        if (save.evaluate().isNotEmpty)
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
        expect(find.text('Новых фото пока нет'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(app(
            DiaryEntryDetailsScreen(
                entry: SubjectDiaryEntry(
                    id: 'local',
                    subjectKey: 'Пример',
                    date: day,
                    text: 'Конспект и выводы. ' * 40,
                    files: [
                  SubjectDiaryFile(
                      name:
                          'Очень длинное название пояснительной записки по расчёту сети.pdf',
                      size: 123456,
                      mime: 'application/pdf',
                      url: 'local-only')
                ])),
            dark));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(repo.writes, 0);
        await tester.pumpWidget(const SizedBox());
        await Supabase.instance.client.realtime.removeAllChannels();
        await Supabase.instance.client.realtime.disconnect();
        Supabase.instance.client.realtime.heartbeatTimer?.cancel();
      });
    }
  }
  for (final photo in [false, true]) {
    Widget screen() => photo
        ? SubjectPhotoConspectScreen(subjectKey: 'Пример', date: day)
        : SubjectQuickNoteScreen(subjectKey: 'Пример', date: day);
    testWidgets('diary failure retry photo=$photo', (tester) async {
      final repo = _Repo()..fail = true;
      SubjectDiaryRepository.instance = repo;
      await tester.pumpWidget(app(screen(), false));
      await tester.pumpAndSettle();
      expect(find.text('Повторить'), findsOneWidget);
      repo.fail = false;
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.text('Повторить'), findsNothing);
      expect(repo.writes, 0);
      await tester.pumpWidget(const SizedBox());
      await Supabase.instance.client.realtime.removeAllChannels();
      await Supabase.instance.client.realtime.disconnect();
      Supabase.instance.client.realtime.heartbeatTimer?.cancel();
    });
    testWidgets('diary delayed read after dispose photo=$photo',
        (tester) async {
      final pending = Completer<List<SubjectDiaryEntry>>();
      final repo = _Repo()..pending = pending;
      SubjectDiaryRepository.instance = repo;
      await tester.pumpWidget(app(screen(), false));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.complete([]);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(repo.writes, 0);
      await Supabase.instance.client.realtime.removeAllChannels();
      await Supabase.instance.client.realtime.disconnect();
      Supabase.instance.client.realtime.heartbeatTimer?.cancel();
    });
  }
}
