import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cold_start_session_test.dart' show sessionFixture;

const _owner = 'test-user';
const _teal = Color(0xff2a9d8f);
const _publication = <String, dynamic>{
  'id': 'cached-news-fixture',
  'title': 'Новости кампуса',
  'body': 'Контрольная публикация',
  'published_at': '2026-11-27T00:00:00Z',
  'created_at': '2026-11-27T00:00:00Z',
  'variant': 'imageOnly',
  'image_path': 'test/first-cover.png',
};

class _Promos implements HomePromoService {
  @override
  Future<HomePromoLoadResult> loadCached() async =>
      const HomePromoLoadResult(intentionallyEmpty: true);

  @override
  Future<HomePromoLoadResult> load({bool writeCache = true}) => loadCached();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ByteData> _cover() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(_teal, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(240, 120);
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.png))!;
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture = Platform.environment['STUDENT_COLD_HOME_CAPTURES'];
  if (capture != null) {
    setUpAll(() async {
      final text = FontLoader('packages/student_ui/WorkspaceSans')
        ..addFont(rootBundle
            .load('packages/student_ui/assets/fonts/NotoSans-Regular.ttf'));
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await Future.wait([text.load(), icons.load()]);
    });
  }
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  sqfliteFfiInit();

  testWidgets(
      'cached cover paints in the first Home frame and on immediate tab return',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    SharedPreferences.setMockInitialValues({
      '${PublishedNewsCache.keyPrefix}__$_owner': jsonEncode([_publication]),
    });
    final remote = Completer<void>();
    final firstFeedRequest = Completer<void>();
    final refreshedCoverRequested = Completer<void>();
    final releaseRefreshedCover = Completer<void>();
    final releaseOfflineRequest = Completer<void>();
    const refreshedTitle = 'Новости кампуса · обновлено';
    var restartOffline = false;
    int networkImageRequests = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    const links = MethodChannel('com.llfbandit.app_links/events');
    messenger.setMockMethodCallHandler(links, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(links, null));
    late HomeDashboardService service;
    late Directory storage;
    late Database db;
    late NewsSqliteImageStore images;
    HomeDashboardService createService() => HomeDashboardService(
          client: Supabase.instance.client,
          publicImageCache: PublicNewsImageCache(openStore: () async => images),
        );
    await tester.runAsync(() async {
      storage = await Directory.systemTemp.createTemp('home-first-frame-');
      db = await databaseFactoryFfi.openDatabase('${storage.path}/index.db');
      images = NewsSqliteImageStore.forCollectionTest(
        database: db,
        root: Directory('${storage.path}/blobs'),
      );
      final entry = mapPublishedNews(_publication).imageCacheKey!;
      final bytes = await _cover();
      expect(
          await images.put(
              entry,
              bytes.buffer
                  .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
              await images.capture(entry)),
          isTrue);
      await Supabase.initialize(
        url: 'https://first-frame-fixture.invalid',
        publishableKey: 'first-frame-fixture',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false, detectSessionInUri: false),
        httpClient: MockClient((request) async {
          Object result = const [];
          if (request.url.path.endsWith('/get_my_published_news')) {
            if (restartOffline) {
              await releaseOfflineRequest.future;
              return http.Response('offline', 503, request: request);
            }
            if (!firstFeedRequest.isCompleted) firstFeedRequest.complete();
            await remote.future;
            result = [
              {
                ..._publication,
                'title': refreshedTitle,
                'updated_at': '2026-11-27T09:00:00Z',
                '_saved_cover_version': 'server-cannot-authorize-cover',
              },
            ];
          } else if (request.url.path.endsWith('/get_my_profile')) {
            result = [
              {'id': _owner, 'name': 'Студент'}
            ];
          } else if (request.url.path.endsWith('/news-media')) {
            networkImageRequests++;
            if (!refreshedCoverRequested.isCompleted) {
              refreshedCoverRequested.complete();
            }
            await releaseRefreshedCover.future;
            return http.Response('unavailable', 404, request: request);
          }
          return http.Response(jsonEncode(result), 200,
              request: request, headers: {'content-type': 'application/json'});
        }),
      );
      final client = Supabase.instance.client;
      await client.auth.setInitialSession(jsonEncode(sessionFixture(
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600)));
      service = createService();
    });
    addTearDown(() async {
      if (!remote.isCompleted) remote.complete();
      if (!releaseRefreshedCover.isCompleted) releaseRefreshedCover.complete();
      if (!releaseOfflineRequest.isCompleted) releaseOfflineRequest.complete();
      service.dispose();
      await Supabase.instance.dispose();
      await db.close();
      await storage.delete(recursive: true);
    });

    final active = ValueNotifier<bool>(true);
    addTearDown(active.dispose);
    final boundaryKey = GlobalKey();
    Widget app() => RepaintBoundary(
          key: boundaryKey,
          child: AuthSessionScopeHost(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme:
                  ProductTheme.build().copyWith(platform: TargetPlatform.iOS),
              home: ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (context, visible, home) => Scaffold(
                  body: IndexedStack(index: visible ? 0 : 1, children: [
                    home!,
                    const Center(child: Text('Другая вкладка')),
                  ]),
                  bottomNavigationBar: Row(children: [
                    TextButton(
                        onPressed: () => active.value = true,
                        child: const Text('Главная')),
                    TextButton(
                        onPressed: () => active.value = false,
                        child: const Text('Профиль')),
                  ]),
                ),
                child: HomeScreen(
                  dashboardService: service,
                  activeListenable: active,
                  promoService: _Promos(),
                ),
              ),
            ),
          ),
        );
    final dashboard = find.byType(StudentHomeView);
    Future<void> mount() async {
      await tester.pumpWidget(app());
      for (var frame = 0;
          dashboard.evaluate().isEmpty && frame < 100;
          frame++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      expect(dashboard, findsOneWidget);
    }

    await mount();
    final card = find.byType(StudentHomeNewsCard);
    Future<void> expectColor(String label) async {
      expect(card.hitTestable(), findsOneWidget,
          reason:
              '$label must already contain the cached feed at the configured position');
      final center = tester.getCenter(card);
      final surface = boundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final sampled = await tester.runAsync(() async {
        final image = await surface.toImage(pixelRatio: 1);
        try {
          final rgba =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          if (capture != null) {
            final png =
                (await image.toByteData(format: ui.ImageByteFormat.png))!;
            await Directory(capture).create(recursive: true);
            await File('$capture/$label.png').writeAsBytes(
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
          }
          final index =
              (center.dy.floor() * image.width + center.dx.floor()) * 4;
          return [
            rgba.getUint8(index),
            rgba.getUint8(index + 1),
            rgba.getUint8(index + 2)
          ];
        } finally {
          image.dispose();
        }
      });
      expect(sampled, [42, 157, 143],
          reason: '$label actual first-frame pixels');
    }

    expect(remote.isCompleted, isFalse);
    await expectColor('cold-first-home-frame');
    await tester.tap(find.text('Профиль'));
    await tester.pump();
    expect(find.text('Другая вкладка'), findsOneWidget);
    await tester.tap(find.text('Главная'));
    await tester.pump();
    await expectColor('first-frame-after-tab-return');
    expect(networkImageRequests, 0);
    await tester.runAsync(
        () => firstFeedRequest.future.timeout(const Duration(seconds: 2)));
    remote.complete();
    bool showedUpdatedFeed = false;
    for (var frame = 0; frame < 100; frame++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
      final thumbnail =
          find.descendant(of: card, matching: find.byType(RawImage));
      expect(tester.widget<RawImage>(thumbnail).image, isNotNull,
          reason: 'a background update must keep the old cover visible');
      showedUpdatedFeed =
          tester.widget<StudentHomeNewsCard>(card).item.title == refreshedTitle;
      if (showedUpdatedFeed && refreshedCoverRequested.isCompleted) break;
    }
    expect(showedUpdatedFeed, isTrue);
    expect(refreshedCoverRequested.isCompleted, isTrue);
    expect(networkImageRequests, 1);
    await expectColor('same-cover-after-refresh');
    releaseRefreshedCover.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await expectColor('same-cover-after-refresh-failure');

    Future<void> restart() async {
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      service = createService();
      await mount();
    }

    restartOffline = true;
    await restart();
    await expectColor('cold-offline-first-frame-after-title-edit');
    expect(tester.widget<StudentHomeNewsCard>(card).item.title, refreshedTitle);
    expect(networkImageRequests, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    final invalidated = Completer<void>();
    Object? invalidationError;
    unawaited(images.invalidate(_publication['image_path'] as String).then((_) {
      invalidated.complete();
    }, onError: (Object error, StackTrace _) {
      invalidationError = error;
      invalidated.complete();
    }));
    for (var frame = 0; !invalidated.isCompleted && frame < 100; frame++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(invalidated.isCompleted, isTrue);
    expect(invalidationError, isNull);
    await restart();
    expect(tester.widget<StudentHomeNewsCard>(card).item.title, refreshedTitle);
    expect(find.descendant(of: card, matching: find.byType(RawImage)),
        findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    releaseOfflineRequest.complete();
    await tester.pump();
  });
}
