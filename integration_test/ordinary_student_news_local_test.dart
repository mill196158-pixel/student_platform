import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:student_platform/src/core/optional_image_cache_budget.dart';
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
    return super.send(request);
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

    Future<void> close() => tap(find.byTooltip('Закрыть'));
    await tester
        .pumpWidget(MaterialApp(home: HomeScreen(dashboardService: service)));
    try {
      for (final (body, color) in [
        ('First control paragraph', 'red'),
        ('Second control paragraph', 'blue')
      ]) {
        await tap(card(body));
        await until(() => find.text(body).hitTestable().evaluate().isNotEmpty,
            'Visible paragraph $body');
        final story = find.byType(StudentNewsStorySheet);
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
      final previousIds = feed().map((item) => item.id).toList();
      await tap(card('First control paragraph'));
      final pages = find.descendant(
          of: find.byType(StudentNewsStorySheet),
          matching: find.byType(PageView));
      await until(() => pages.hitTestable().evaluate().isNotEmpty,
          'First reader page ready');
      await tester.drag(pages, Offset(-tester.getSize(pages).width * .8, 0));
      await tester.pump(const Duration(milliseconds: 500));
      await until(
          () => find
              .text('Second control paragraph')
              .hitTestable()
              .evaluate()
              .isNotEmpty,
          'Second reader page after student swipe');
      await close();
      await until(
          () => find
              .byType(StudentNewsStorySheet, skipOffstage: false)
              .evaluate()
              .isEmpty,
          'Reader closed before refreshing the home feed');
      await client.rpc('fixture_publish');
      final refresh = find.byType(RefreshIndicator);
      final bounds = tester.getRect(refresh);
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.timedDragFrom(
            Offset(bounds.center.dx, bounds.top + bounds.height * .25),
            Offset(0, bounds.height * .65),
            const Duration(milliseconds: 520));
        await tester.pump(const Duration(milliseconds: 450));
        if (feed().first.title == 'Latest post') break;
      }
      await until(() => card('Fresh paragraph').evaluate().isNotEmpty,
          'Published story visible after refresh');
      final items = feed();
      expect(items.first.title, 'Latest post');
      expect(items.map((item) => item.id).toSet().length, items.length);
      expect(items.skip(1).map((item) => item.id), orderedEquals(previousIds));
      debugPrint(
          'E2E-083 two reader pages, pull to refresh, new first row and unchanged ordered prior IDs; single server batch');
      await tap(card('First control paragraph'));
      final activeStory = find.byType(StudentNewsStorySheet);
      await until(
          () =>
              find
                  .descendant(
                      of: activeStory, matching: find.text('Campus revised'))
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty &&
              find
                  .descendant(
                      of: activeStory,
                      matching: find.text('First control paragraph'))
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty,
          'Revised headline and its original paragraph within the open reader');
      await close();
      debugPrint(
          'PARTIAL E2E-081 revised headline and body in home reader; no separate student news route');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await client.auth.signOut();
    }
  });
}
