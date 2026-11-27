import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_content_coordinator.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/home_screen.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _owner = 'july-welcome-upgrade-fixture';
const _project = SupabaseConfig.url;
const _promoTitle = 'Сохранённое объявление';
const _coverHash =
    'd65fdaa33f8f7ea1df3e7cce10c3f9e25047e036a0b3f475fd48af94aef0b71a';
const _article = <String, dynamic>{
  'id': '9658bbcf-7fc8-48cc-ae1f-21b1a0ad1523',
  'title': 'Новое приложение',
  'subtitle': 'Добро пожаловать',
  'body': 'Тест первого кадра публикации от 22 июля.',
  'image_path':
      'news/11c2995c-a5c0-40d3-87e2-422fa479543a/02013116-6a91-4e5f-9b4e-bddc90a1ba32.jpg',
  'created_at': '2026-07-22T11:17:12.921959Z',
  'published_at': '2026-07-22T11:24:18.637502Z',
  'updated_at': '2026-11-06T11:38:39.653775Z',
  'variant': 'imageOverlay',
  'version_number': 5,
  'image_focus_x': -1,
  'image_focus_y': 0,
  'overlay_opacity': 0.42,
  'gradient_colors': ['#7367F0', '#B784F7'],
};
final _oldArticle = <String, dynamic>{
  ..._article,
  'image_path':
      'news/11c2995c-a5c0-40d3-87e2-422fa479543a/34d8b496-cb08-4cdb-9bb9-16604f9dbada.jpg',
  'updated_at': '2026-07-22T12:16:47.478522Z',
  'version_number': 4,
};

String _session() {
  String part(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final claims = part({
    'iss': '$_project/auth/v1',
    'sub': _owner,
    'session_id': '11111111-1111-4111-8111-111111111111',
    'aud': 'authenticated',
    'role': 'authenticated',
    'iat': expires - 3660,
    'exp': expires,
  });
  return jsonEncode({
    'access_token': '${part({'alg': 'HS256'})}.$claims.fixture',
    'refresh_token': 'july-welcome-fixture-token',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': expires,
    'user': {'id': _owner, 'aud': 'authenticated', 'created_at': '2026-01-01'},
  });
}

Future<Uint8List> _promoBytes() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xffed8a2f), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(80, 40);
  try {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _capture(
    WidgetTester tester, GlobalKey boundary, String name) async {
  final folder = Platform.environment['STUDENT_WELCOME_FRAME_CAPTURES'];
  if (folder == null) return;
  final paint =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final raster = await paint.toImage(pixelRatio: 1);
    try {
      final png = (await raster.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(folder).create(recursive: true);
      await File('$folder/$name.png').writeAsBytes(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
    } finally {
      raster.dispose();
    }
  });
}

Finder? _decodedPhoto(WidgetTester tester, Finder parent) {
  final sources = find.descendant(of: parent, matching: find.byType(Image));
  for (final image in tester.widgetList<Image>(sources)) {
    final source = image.image;
    final original = source is ResizeImage ? source.imageProvider : source;
    if (original is! MemoryImage ||
        sha256.convert(original.bytes).toString() != _coverHash) {
      continue;
    }
    final rendered = find.descendant(
        of: find.byWidget(image), matching: find.byType(RawImage));
    if (tester
        .widgetList<RawImage>(rendered)
        .any((widget) => widget.image != null)) {
      return rendered;
    }
  }
  return null;
}

Future<bool> _photoOnRaster(
    WidgetTester tester, GlobalKey boundary, Finder? image) async {
  if (image == null) return false;
  final photo = tester.getRect(image);
  final paint =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final offset = paint.globalToLocal(photo.topLeft);
  return (await tester.runAsync(() async {
    final raster = await paint.toImage(pixelRatio: 1);
    try {
      final pixels =
          (await raster.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      var samples = 0;
      var warm = 0;
      // Look inside the upper crop, away from corner clipping and title text.
      // Real warm stone/skin tones here distinguish the photo from the blue-purple fallback.
      for (var y = (offset.dy + photo.height * .1).round();
          y < offset.dy + photo.height * .42 && y < raster.height;
          y += 3) {
        for (var x = (offset.dx + photo.width * .18).round();
            x < offset.dx + photo.width * .82 && x < raster.width;
            x += 3) {
          if (x < 0 || y < 0) continue;
          final pixel = (y * raster.width + x) * 4;
          final red = pixels.getUint8(pixel);
          final green = pixels.getUint8(pixel + 1);
          final blue = pixels.getUint8(pixel + 2);
          samples++;
          if (red > blue + 12 && red > green + 5) warm++;
        }
      }
      return samples > 100 && warm > samples * .12;
    } finally {
      raster.dispose();
    }
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.environment['STUDENT_WELCOME_FRAME_CAPTURES'] != null) {
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

  for (final (mode, offline, evicted, oldMetadata) in [
    ('slow-network', false, false, false),
    ('offline', true, false, false),
    ('evicted-temp-file', false, true, false),
    ('older-metadata', false, false, true),
  ]) {
    testWidgets('July welcome first frames after upgrade, $mode',
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
        '${PublishedNewsCache.keyPrefix}__$_owner':
            jsonEncode([oldMetadata ? _oldArticle : _article]),
      });
      final transportGate = Completer<void>();
      final authEvents = StreamController<AuthState>.broadcast(sync: true);
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add(request.url.path);
        await transportGate.future;
        return http.Response('Fixture transport unavailable', 503,
            request: request);
      });
      final messenger = tester.binding.defaultBinaryMessenger;
      const links = MethodChannel('com.llfbandit.app_links/events');
      messenger.setMockMethodCallHandler(links, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(links, null));

      late Directory root;
      late Database contentDb, optionalDb;
      late AuthSessionScope scope;
      late SessionCapabilities capabilities;
      late HomeSnapshotCache homeCache;
      late HomeContentCoordinator coordinator;
      late OnlineSideEffectBarrier barrier;
      late HomeDashboardService dashboard;
      await tester.runAsync(() async {
        final photoPath =
            Platform.environment['STUDENT_WELCOME_COVER_FIXTURE'] ??
                'test/fixtures/july_welcome_cover.jpg';
        final photo = await File(photoPath).readAsBytes();
        expect(sha256.convert(photo).toString(), _coverHash);
        await Supabase.initialize(
            url: _project,
            publishableKey: 'welcome-fixture-key',
            httpClient: mock,
            authOptions: const FlutterAuthClientOptions(
                autoRefreshToken: false, detectSessionInUri: false));
        final client = Supabase.instance.client;
        await client.auth.setInitialSession(_session());
        scope = AuthSessionScope(
            currentSession: () => client.auth.currentSession,
            authEvents: authEvents.stream);
        authEvents.add(AuthState(
            AuthChangeEvent.initialSession, client.auth.currentSession));
        capabilities = SessionCapabilities(scope);
        final owner = scope.capture()!;
        barrier = OnlineSideEffectBarrier(
            ownerIsCurrent: () => scope.isCurrent(owner));
        expect(
            capabilities.grant(
                offline
                    ? SessionCapabilityMode.cacheOnly
                    : SessionCapabilityMode.online,
                capabilities.beginAuthorization(owner)!),
            isTrue);
        homeCache = HomeSnapshotCache(
            project: _project,
            authScope: scope,
            currentUserId: () => scope.capture()?.userId,
            sessionGeneration: () => scope.generation,
            sessionIdentity: scope.capture);

        root = await Directory.systemTemp.createTemp('welcome-upgrade-');
        contentDb = await openHomeContentSnapshotDatabase(
            '${root.path}/durable.db',
            factory: databaseFactoryFfi);
        optionalDb =
            await databaseFactoryFfi.openDatabase('${root.path}/optional.db');
        final store = HomeContentSnapshotStore(
            db: contentDb,
            project: _project,
            scope: scope,
            currentBinding: () => scope.bindingFor(owner, '$_project/auth/v1'));
        final durableKey = 'news:${_article['id']}:$_coverHash';
        final savedNews = HomeContentSnapshot([
          {..._article, '_offline_image': durableKey}
        ], {
          durableKey: photo
        });
        final savedPromo = HomeContentSnapshot([
          {
            'id': 'promo-keep',
            'template_key': 'home_promo_v1',
            'schema_version': 2,
            'origin': 'admin',
            'placement': 'home_promo',
            '_offline_image': 'promo-cover',
            'payload': {
              'title': _promoTitle,
              'subtitle': 'Объявление',
              'icon_key': 'psychology',
              'cta_label': 'Открыть',
              'dismissible': false,
              'gradient_colors': ['#FFFBFF', '#F3EEF9'],
              'card_variant': 'image_full',
              'home_slot': 'after_news',
              'image_asset_id': 'promo-cover'
            },
          },
        ], {
          'promo-cover': await _promoBytes()
        });
        for (final (section, snapshot) in [
          ('news', savedNews),
          ('promo', savedPromo)
        ]) {
          final ticket = await store.begin(section,
              isCurrent: () => scope.isCurrent(owner));
          expect(ticket, isNotNull);
          expect(await store.commit(ticket!, snapshot), isTrue);
        }
        final optionalRoot = Directory('${root.path}/optional-blobs');
        final optionalImages = NewsSqliteImageStore.forCollectionTest(
            database: optionalDb, root: optionalRoot);
        final publicImages = PublicNewsImageCache(
            openStore: () async => optionalImages,
            legacy: NewsImageDiskCache(
                rootOverride: () => Directory('${root.path}/legacy')));
        // Installation preserves the previous verified account snapshot, while
        // iOS can evict the independent optional/temporary image cache.
        final coverKey = mapPublishedNews(_article).imageCacheKey!;
        if (evicted) {
          expect(
              await optionalImages.put(
                  coverKey, photo, await optionalImages.capture(coverKey)),
              isTrue);
          final blobs = await optionalRoot
              .list()
              .where((file) => file.path.endsWith('.bin'))
              .toList();
          expect(blobs, hasLength(1));
          await blobs.single.delete();
        }
        expect((await publicImages.read(coverKey)).state,
            evicted ? NewsImageReadState.unknown : NewsImageReadState.miss);
        coordinator = HomeContentCoordinator(
            store: store, scope: scope, httpClient: mock);
        dashboard = HomeDashboardService(
            client: client,
            sessionScope: scope,
            projectSnapshotCache: homeCache,
            publicImageCache: publicImages,
            readVerifiedNews:
                offline ? null : () => coordinator.readOnline('news', barrier),
            httpClient: mock);
      });

      final reader = offline
          ? CachedHomeScheduleReader(
              capabilities: capabilities,
              home: homeCache,
              schedule: ScheduleMonthCache(scope, _project))
          : null;
      final active = ValueNotifier<bool>(true);
      final boundary = GlobalKey();
      Future<void> firstFrame(Finder finder) async {
        for (var frame = 0; finder.evaluate().isEmpty && frame < 200; frame++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        expect(finder, findsOneWidget);
      }

      try {
        await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: AuthSessionScopeHost(
              createScope: () => scope,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme:
                    ProductTheme.build().copyWith(platform: TargetPlatform.iOS),
                home: ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (_, visible, home) => Scaffold(
                    body: IndexedStack(index: visible ? 0 : 1, children: [
                      home!,
                      const Center(child: Text('Другая вкладка'))
                    ]),
                  ),
                  child: HomeScreen(
                      dashboardService: dashboard,
                      activeListenable: active,
                      homeContent: coordinator,
                      cachedReader: reader,
                      homeContentCapabilities: offline ? capabilities : null,
                      onlineBarrier: offline ? null : barrier),
                ),
              )),
        ));

        final home = find.byType(StudentHomeView);
        final card = find.byType(StudentHomeNewsCard);
        final sheet = find.byType(StudentNewsStorySheet);
        await firstFrame(home);
        expect(card.hitTestable(), findsOneWidget);
        final homePhoto =
            await _photoOnRaster(tester, boundary, _decodedPhoto(tester, card));
        final promo = find.widgetWithText(StudentHomePromoCard, _promoTitle);
        final promoRaster =
            find.descendant(of: promo, matching: find.byType(RawImage));
        expect(tester.widget<RawImage>(promoRaster).image, isNotNull);
        await _capture(tester, boundary, '$mode-first-home');

        active.value = false;
        await tester.pump();
        expect(find.text('Другая вкладка'), findsOneWidget);
        active.value = true;
        await tester.pump();
        final returnedPhoto =
            await _photoOnRaster(tester, boundary, _decodedPhoto(tester, card));
        expect(tester.widget<RawImage>(promoRaster).image, isNotNull);
        await _capture(tester, boundary, '$mode-tab-return');

        await tester.tap(card);
        await firstFrame(sheet);
        final firstStoryImage = _decodedPhoto(tester, sheet);
        // Ensure the very same first-frame image is drawn once its first upper
        // crop has moved into view during the normal sheet transition.
        if (firstStoryImage != null) {
          for (var step = 0; step < 20; step++) {
            final bounds = tester.getRect(firstStoryImage);
            if (bounds.top + bounds.height * .42 <= 844) break;
            await tester.pump(const Duration(milliseconds: 16));
          }
        }
        final storyPhoto =
            await _photoOnRaster(tester, boundary, firstStoryImage);
        await tester.pump(const Duration(milliseconds: 300));
        await _capture(tester, boundary, '$mode-opened-story');
        expect(transportGate.isCompleted, isFalse);
        if (offline) expect(paths, isEmpty);
        debugPrint('July welcome frames $mode home=$homePhoto '
            'return=$returnedPhoto story=$storyPhoto');
        expect([homePhoto, returnedPhoto, storyPhoto], [true, true, true],
            reason: 'Original July JPEG decoded on all three first frames');
        expect(paths.where((path) => path.endsWith('/news-media')), isEmpty);
      } finally {
        barrier.close();
        dashboard.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        active.dispose();
        transportGate.complete();
        await tester.pump();
        await tester.pump(const Duration(seconds: 20));
        for (var turn = 0; barrier.activeCount != 0 && turn < 180; turn++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        expect(barrier.activeCount, 0);
        coordinator.dispose();
        capabilities.dispose();
        await authEvents.close();
        var closed = false;
        Object? closeError;
        unawaited(() async {
          try {
            await Supabase.instance.dispose();
            await optionalDb.close();
            await contentDb.close();
            await root.delete(recursive: true);
          } catch (error) {
            closeError = error;
          } finally {
            closed = true;
          }
        }());
        for (var turn = 0; !closed && turn < 180; turn++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        expect(closeError, isNull);
        expect(closed, isTrue);
      }
    });
  }
}
