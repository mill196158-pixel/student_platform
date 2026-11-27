import 'dart:async';
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
  int feedReads = 0;
  int rejectedReads = 0;
  bool rejectFeedRequests = false;

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
    if (request.url.path.endsWith('/rpc/get_my_published_news')) {
      feedReads++;
      if (rejectFeedRequests) {
        rejectedReads++;
        throw const SocketException('QA feed connection interrupted');
      }
    }
    return super.send(request);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final config = Platform.environment['STUDENT_NEWS_LOCAL'];
  if (config == null) {
    test('requires isolated student news account', () {}, skip: true);
    return;
  }
  testWidgets(
      'student reads matching publications, refreshes and handles missing cover',
      (tester) async {
    await binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => binding.setSurfaceSize(null));
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

    Future<void> openCard(String body) async {
      final strip = find.byType(StudentHomeNewsFeed);
      await until(() => strip.evaluate().isNotEmpty, 'Home news strip mounted');
      if (strip.hitTestable().evaluate().isEmpty) {
        await tester.ensureVisible(strip);
        await tester.pump(const Duration(milliseconds: 350));
      }
      await until(
          () => strip.hitTestable().evaluate().isNotEmpty, 'Home news strip');
      final list = find.descendant(of: strip, matching: find.byType(ListView));
      final scroll = tester.state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first);
      final target = card(body);
      for (var attempt = 0;
          attempt < 28 &&
              scroll.position.pixels > 1.0 &&
              target.hitTestable().evaluate().isEmpty;
          attempt++) {
        await tester.drag(list, const Offset(240, 0));
        await tester.pumpAndSettle();
      }
      for (var attempt = 0;
          attempt < 35 &&
              scroll.position.extentAfter > 1.0 &&
              target.hitTestable().evaluate().isEmpty;
          attempt++) {
        await tester.drag(list, const Offset(-240, 0));
        await tester.pumpAndSettle();
      }
      await tap(target);
      await until(
          () => find
              .descendant(
                  of: find.byType(StudentNewsStorySheet),
                  matching: find.text(body))
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'News reader opened: $body');
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
        await openCard(body);
        await until(() => find.text(body).hitTestable().evaluate().isNotEmpty,
            'Visible paragraph $body');
        final story = find.byType(StudentNewsStorySheet);
        expect(find.textContaining(' из 27'), findsOneWidget);
        final hero = find.descendant(of: story, matching: find.byType(Image));
        bool decodedCover(Image image) {
          final provider = image.image;
          final source = provider is ResizeImage ? provider.imageProvider : provider;
          if (source is! MemoryImage ||
              base64Encode(source.bytes) != base64Encode(_covers[color]!)) {
            return false;
          }
          final rendered = find.descendant(
              of: find.byWidget(image), matching: find.byType(RawImage));
          return tester.widgetList<RawImage>(rendered).any((raw) => raw.image != null);
        }
        await until(
            () => tester.widgetList<Image>(hero).any(decodedCover),
            'Story cover $color');
        await close();
      }
      debugPrint(
          'PASS E2E-082 two matching titles opened distinct illustrated publications');
      await openCard('Readable without a cover');
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
      final snapshot = feed();
      final oldIds = snapshot.map((item) => item.id).toList();
      expect(oldIds, hasLength(27));
      for (final title in [
        'Private bulletin',
        'Hidden QA',
        'Expired QA',
        'Draft QA'
      ]) {
        expect(snapshot.map((item) => item.title), isNot(contains(title)));
      }
      expect(find.text('Все новости'), findsNothing);

      await openCard('First control paragraph');
      final sheet = find.byType(StudentNewsStorySheet);
      final pager = find
          .descendant(of: sheet, matching: find.byType(PageView))
          .hitTestable();
      await until(() => pager.evaluate().isNotEmpty, 'Reader swipe area');
      final opened = tester.widget<StudentNewsStorySheet>(sheet);
      expect(opened.news.map((item) => item.id), orderedEquals(oldIds));
      expect(opened.news[opened.initialIndex].body, 'First control paragraph');
      await tester.timedDrag(
          pager, const Offset(-300, 0), const Duration(milliseconds: 360));
      await tester.pumpAndSettle();
      final controller = tester.widget<PageView>(pager).controller!;
      expect(
          controller.page, closeTo((opened.initialIndex + 1).toDouble(), .01));
      expect(
          find.text('Second control paragraph').hitTestable(), findsOneWidget);
      await close();

      Future<void> refresh() async {
        final indicator = find.byType(RefreshIndicator);
        await until(() => indicator.hitTestable().evaluate().isNotEmpty,
            'Home refresh');
        final previous = transport.feedReads;
        // Exercise the refresh control itself after the native test window
        // changes size. Overscroll gestures depend on the host scroll adapter.
        unawaited(tester.state<RefreshIndicatorState>(indicator).show());
        await tester.pump(const Duration(milliseconds: 350));
        await until(() => transport.feedReads > previous,
            'Home requested feed refresh');
        await tester.pumpAndSettle();
      }

      await client.rpc('fixture_publish');
      transport.rejectFeedRequests = true;
      await refresh();
      expect(transport.rejectedReads, greaterThan(0));
      expect(feed().map((item) => item.id), orderedEquals(oldIds));
      await openCard('First control paragraph');
      expect(
          find.text('First control paragraph').hitTestable(), findsOneWidget);
      await close();
      transport.rejectFeedRequests = false;
      await refresh();
      await until(() => feed().first.title == 'Latest post',
          'Published feed refreshed');
      final newIds = feed().map((item) => item.id).toList();
      expect(newIds, hasLength(28));
      expect(newIds.toSet().length, 28);
      expect(newIds.skip(1), orderedEquals(oldIds));
      expect(find.text('Все новости'), findsNothing);
      await tester.runAsync(() => capture('news_home'));

      await openCard('First control paragraph');
      await until(
          () => find
              .descendant(of: sheet, matching: find.text('Campus revised'))
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'Revised title in home reader');
      final revised = tester.widget<StudentNewsStorySheet>(sheet);
      expect(revised.news[revised.initialIndex].id, oldIds.first);
      expect(
          revised.news[revised.initialIndex].body, 'First control paragraph');
      debugPrint(
          'PASS E2E-081 home feed opens the same publication with revised title and body without a separate button');
      debugPrint(
          'PASS E2E-083 swiped two feed cards, kept 27 rows during transport failure, then refreshed with one new ID and preserved order');

      final previousTap = tester
          .widget<StudentHomeView>(find.byType(StudentHomeView))
          .onNewsTap!;
      final second = fixture['accounts'][1];
      await client.auth.signInWithPassword(
          email: second['email'], password: second['password']);
      await until(() => sheet.evaluate().isEmpty,
          'Previous student reader closed on account switch');
      await until(
          () =>
              find.byType(StudentHomeView).evaluate().isNotEmpty &&
              feed().any((item) => item.title == 'Private bulletin'),
          'Own audience entry in second account');
      previousTap(0);
      await tester.pump(const Duration(milliseconds: 350));
      expect(sheet, findsNothing);
      debugPrint('PASS stale home news tap ignored after account change');
      await openCard('Other audience');
      expect(find.text('Other audience').hitTestable(), findsOneWidget);
      debugPrint(
          'PASS foreign audience hidden for first account, second account opened its own publication');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await client.auth.signOut();
    }
  });
}
