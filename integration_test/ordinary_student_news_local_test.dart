import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/news_archive_screen.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/local_schema_http_client.dart';

final _covers = {
  'red': base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP8zwACTGCSAQANHQEDgslx/wAAAABJRU5ErkJggg=='),
  'blue': base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGNkYPjPwMDAxAAGAAsfAQMU4wsAAAAAAElFTkSuQmCC'),
};

// The isolated fixture supplies image URLs. The app downloads and decodes the
// returned bytes over real HTTP. Auth and feed RPCs go to the local backend.
class _NewsTransport extends LocalSchemaHttpClient {
  _NewsTransport(super.port, this.mediaPort);
  final int mediaPort;
  final pageCalls = <Map<String, dynamic>>[];
  final pages = <List<Map<String, dynamic>>>[];
  int pageMissing = 0;
  int legacyReads = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/functions/v1/news-media') {
      final payload = jsonDecode(await request.finalize().bytesToString());
      final name = (payload['path'] as String).split('/').last;
      return http.StreamedResponse(
          Stream.value(utf8.encode(
              jsonEncode({'signedUrl': 'http://127.0.0.1:$mediaPort/$name'}))),
          200,
          headers: {'content-type': 'application/json'});
    }
    final path = request.url.path;
    if (path.endsWith('/rpc/get_my_published_news')) legacyReads++;
    if (!path.endsWith('/rpc/get_my_published_news_page'))
      return super.send(request);
    pageCalls.add(
        jsonDecode((request as http.Request).body) as Map<String, dynamic>);
    final response = await super.send(request);
    final bytes = await response.stream.toBytes();
    final body = jsonDecode(utf8.decode(bytes));
    if (response.statusCode == 200) {
      pages.add((body as List).cast<Map<String, dynamic>>());
    } else if (body['code'] == 'PGRST202') {
      pageMissing++;
    }
    return http.StreamedResponse(Stream.value(bytes), response.statusCode,
        headers: response.headers, request: response.request);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = Platform.environment['STUDENT_NEWS_LOCAL'];
  if (config == null) {
    test('requires isolated student news account', () {}, skip: true);
    return;
  }
  testWidgets(
      'student reads matching publications, refreshes and handles missing cover',
      (tester) async {
    final fixture = jsonDecode(config);
    final schema = fixture['schema'] as String;
    expect(schema, matches(RegExp(r'^e2e_news_[a-f0-9]{12}$')));
    SharedPreferences.setMockInitialValues({});
    final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => media.close(force: true));
    media.listen((request) async {
      final bytes = _covers[request.uri.pathSegments.last];
      if (bytes == null) {
        request.response.statusCode = 404;
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(bytes);
      }
      await request.response.close();
    });
    final transport = _NewsTransport(fixture['restPort'], media.port);
    addTearDown(transport.close);
    await Supabase.initialize(
        url: localSupabaseUrl,
        publishableKey: fixture['anon'],
        httpClient: transport,
        postgrestOptions: PostgrestClientOptions(schema: schema),
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage()));
    final client = Supabase.instance.client;
    addTearDown(() => Supabase.instance.dispose());
    final signed = await client.auth.signInWithPassword(
        email: fixture['email'], password: fixture['password']);
    expect(signed.user?.id, fixture['student']);
    sqfliteFfiInit();
    final temp = await Directory.systemTemp.createTemp('student-news-');
    addTearDown(() => temp.delete(recursive: true));
    final db = await databaseFactoryFfi.openDatabase('${temp.path}/index.db');
    addTearDown(db.close);
    final disk = NewsSqliteImageStore.forCollectionTest(
        database: db, root: Directory('${temp.path}/blobs'));
    final images = PublicNewsImageCache(
        openStore: () async => disk,
        budget: OptionalImageCacheBudget(roots: () async => [temp]));
    final service =
        HomeDashboardService(client: client, publicImageCache: images);
    Future<void> until(bool Function() match, String reason) async {
      final guard = Stopwatch()..start();
      while (!match() && guard.elapsed < const Duration(seconds: 18)) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(match(), isTrue, reason: reason);
    }

    Finder card(String body) => find.byWidgetPredicate(
        (w) => w is StudentHomeNewsCard && w.item.body == body);
    Future<void> tap(Finder f) async {
      await until(() => f.evaluate().isNotEmpty, 'Missing $f');
      await tester.ensureVisible(f.first);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(f.first);
      await tester.pump(const Duration(milliseconds: 350));
    }

    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      final directory = Platform.environment['STUDENT_NEWS_ARTIFACT_DIR'];
      if (directory == null) return;
      final render =
          boundary.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$directory/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }

    Future<void> enterArchive() async {
      final view = find.byType(StudentHomeView);
      await until(() => view.hitTestable().evaluate().isNotEmpty,
          'Dashboard after closing reader');
      expect(tester.widget<StudentHomeView>(view).onAllNewsTap, isNotNull,
          reason: 'Authenticated dashboard must expose the archive action');
      final homeScroll = find
          .descendant(of: view, matching: find.byType(CustomScrollView))
          .first;
      for (var i = 0;
          i < 12 && find.text('Все новости').hitTestable().evaluate().isEmpty;
          i++) {
        await tester.drag(homeScroll, const Offset(0, 300));
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tap(find.text('Все новости'));
    }

    Future<void> close() => tap(find.byTooltip('Закрыть'));
    await tester.pumpWidget(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
          width: 390,
          height: 844,
          child: RepaintBoundary(
              key: boundary,
              child: AuthSessionScopeHost(
                  child: MaterialApp(
                      debugShowCheckedModeBanner: false,
                      locale: const Locale('ru', 'RU'),
                      supportedLocales: const [Locale('ru', 'RU')],
                      localizationsDelegates:
                          GlobalMaterialLocalizations.delegates,
                      home: HomeScreen(dashboardService: service))))),
    ));
    try {
      for (final (body, color) in [
        ('First control paragraph', 'red'),
        ('Second control paragraph', 'blue')
      ]) {
        await tap(card(body));
        await until(() => find.text(body).hitTestable().evaluate().isNotEmpty,
            'Visible paragraph $body');
        final story = find.byType(StudentNewsStorySheet);
        expect(find.textContaining(' из 27'), findsOneWidget);
        await until(
            () => tester
                .widgetList<Image>(
                    find.descendant(of: story, matching: find.byType(Image)))
                .where((w) => w.image is MemoryImage)
                .any((w) =>
                    base64Encode((w.image as MemoryImage).bytes) ==
                    base64Encode(_covers[color]!)),
            'Story cover $color');
        await close();
      }
      debugPrint(
          'PASS E2E-082 two matching titles opened distinct illustrated publications');
      await tap(card('Readable without a cover'));
      await until(
          () => find
              .text('Readable without a cover')
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'Missing cover story');
      await close();
      await until(() => find.byType(StudentNewsStorySheet).evaluate().isEmpty,
          'Return to home');
      debugPrint(
          'PASS E2E-084 failed image request permits reading and return');
      List<StudentHomeNews> feed() => tester
          .widget<StudentHomeView>(find.byType(StudentHomeView))
          .data
          .news;
      final rootId = feed()
          .firstWhere((item) => item.body == 'First control paragraph')
          .id;
      final archive = find.byType(NewsArchiveScreen);
      final rows =
          find.descendant(of: archive, matching: find.byType(ListTile));
      final list =
          find.descendant(of: archive, matching: find.byType(ListView));
      Future<List<String>> readRows() async {
        final scroll = tester.state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)).first);
        Future<void> drag(double dy) async {
          await tester.drag(list, Offset(0, dy));
          await tester.pumpAndSettle();
        }

        for (var i = 0; i < 40 && scroll.position.pixels > 0.5; i++) {
          await drag(350);
        }
        final ids = <String>{};
        for (var i = 0; i < 40; i++) {
          for (final row in tester.widgetList<ListTile>(rows.hitTestable())) {
            ids.add((row.key as ValueKey<String>)
                .value
                .substring('news-row-'.length));
          }
          if (scroll.position.extentAfter < 1) break;
          await drag(-220);
        }
        return ids.toList();
      }

      final legacyBefore = transport.legacyReads;
      await enterArchive();
      await until(() => rows.evaluate().isNotEmpty, 'Archive first page');
      final legacy = fixture['legacy'] == true;
      final List<String> oldIds;
      if (legacy) {
        expect(transport.pageMissing, 1);
        expect(transport.legacyReads, greaterThan(legacyBefore));
        oldIds = await readRows();
        expect(oldIds, hasLength(27));
        expect(find.text('Показать ещё'), findsNothing);
        debugPrint(
            'PASS compatibility: stock pre-migration RPC returned the full authorized archive');
      } else {
        await tester.runAsync(() => capture('news_archive'));
        final initial = await readRows();
        expect(initial, hasLength(20));
        expect(transport.pageCalls, hasLength(1));
        expect(transport.pageCalls.first['p_after'], isNull);
        expect(transport.pages.first, hasLength(21));
        expect(
            initial,
            orderedEquals(
                transport.pages.first.take(20).map((row) => row['id'])));
        await tap(find.text('Показать ещё'));
        await until(() => transport.pages.length == 2, 'Second server page');
        await tester.pumpAndSettle();
        oldIds = await readRows();
        expect(oldIds, hasLength(27));
        final cutoff = transport.pages.first[19];
        expect(transport.pageCalls[1]['p_after'], {
          for (final key in ['id', 'sort_order', 'priority', 'published_at'])
            key: cutoff[key]
        });
        final expected = [
          ...transport.pages.first.take(20),
          ...transport.pages[1]
        ];
        expect(oldIds, orderedEquals(expected.map((r) => r['id'])));
        final tiedIds = expected
            .where((r) => r['sort_order'] == 10)
            .map((r) => r['id'] as String)
            .toList();
        expect(tiedIds, orderedEquals(tiedIds.toList()..sort()));
        expect(expected.map((r) => r['title']),
            isNot(contains('Private bulletin')));
        expect(expected.map((r) => r['title']), isNot(contains('Hidden QA')));
        expect(expected.map((r) => r['title']), isNot(contains('Draft QA')));
        expect(expected.map((r) => r['title']), isNot(contains('Expired QA')));
      }
      await client.rpc('fixture_publish');
      await tap(find.byTooltip('Обновить новости'));
      await until(
          () =>
              tester
                  .widget<IconButton>(find.byWidgetPredicate((widget) =>
                      widget is IconButton &&
                      widget.tooltip == 'Обновить новости'))
                  .onPressed !=
              null,
          'Archive refresh finished');
      await tester.pumpAndSettle();
      final newIds = await readRows();
      expect(newIds, hasLength(28));
      if (legacy) {
        expect(transport.pageMissing, 2);
        expect(newIds.skip(1), unorderedEquals(oldIds));
        debugPrint(
            'PASS E2E-083 compatibility: refreshed the full archive through the legacy RPC, 27 previous IDs and one new ID');
      } else {
        expect(transport.pages, hasLength(4));
        expect(newIds.skip(1), orderedEquals(oldIds));
        expect(transport.pages[2].first['title'], 'Latest post');
        expect(transport.pages[2].first['id'], newIds.first);
        debugPrint(
            'PASS E2E-083 ordinary archive read two distinct SQL pages; after real publication refresh preserves all 27 previous IDs, including the equal-timestamp boundary');
      }
      // Scroll back to the revised publication and open it through the archive.
      final revised =
          find.descendant(of: archive, matching: find.text('Campus revised'));
      for (var i = 0; i < 30 && revised.hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(list, const Offset(0, 350));
        await tester.pumpAndSettle();
      }
      Future<void> checkRevised() async {
        final sheet = find.byType(StudentNewsStorySheet);
        await until(
            () =>
                find
                    .descendant(
                        of: sheet, matching: find.text('Campus revised'))
                    .hitTestable()
                    .evaluate()
                    .isNotEmpty &&
                find
                    .descendant(
                        of: sheet,
                        matching: find.text('First control paragraph'))
                    .hitTestable()
                    .evaluate()
                    .isNotEmpty,
            'Revised headline and original paragraph');
        final story = tester.widget<StudentNewsStorySheet>(sheet);
        expect(story.news[story.initialIndex].id, rootId);
        await close();
        await until(() => sheet.evaluate().isEmpty, 'Reader closed');
      }

      await tap(revised);
      await checkRevised();
      await tap(
          find.descendant(of: archive, matching: find.byType(BackButton)));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(find.byType(RefreshIndicator));
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.timedDragFrom(Offset(bounds.center.dx, bounds.top + 100),
            Offset(0, bounds.height * .65), const Duration(milliseconds: 520));
        await tester.pump(const Duration(milliseconds: 450));
        if (feed().first.title == 'Latest post') break;
      }
      await until(
          () => feed().first.title == 'Latest post', 'Home news refreshed');
      await tap(card('First control paragraph'));
      await checkRevised();
      debugPrint(
          'PASS E2E-081 home and archive open the same edited publication UUID, heading and paragraph');
      await enterArchive();
      await until(() => rows.evaluate().isNotEmpty,
          'Archive visible before changing account');
      final second = fixture['accounts'][1];
      await client.auth.signInWithPassword(
          email: second['email'], password: second['password']);
      await until(() => archive.evaluate().isEmpty,
          'Previous student archive closed on account switch');
      await enterArchive();
      await until(
          () => find
              .descendant(of: archive, matching: find.text('Private bulletin'))
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'Own audience entry in second account');
      debugPrint(
          'PASS foreign audience hidden for first account, second account opens its own publication, previous archive dismissed');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await client.auth.signOut();
    }
  });
}
