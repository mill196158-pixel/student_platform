import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
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
import 'package:student_platform/src/ui/home/home_snapshot_codec.dart';
import 'package:student_platform/src/ui/home/models/home_dashboard_data.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';
import 'package:student_platform/src/ui/learning/models/assignment.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_platform/src/ui/schedule/utils/msk_date.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _profileName = 'Снимок';
const _group = 'Сохр-01';
const _lesson = 'Гидравлика';
const _assignment = 'Сохранить расчёт';
const _hero = 'Учебная неделя';
const _shortcut = 'Разбор задач';
const _teal = 0x238a7b;
const _blue = 0x275cbd;
const _amber = 0xf29a25;
const _plum = 0x922f91;
const _owner = 'home-frame-owner';
const _otherOwner = 'home-frame-new-owner';
const _project = SupabaseConfig.url;

Map<String, dynamic> _news(String id, String title) => {
      'id': id,
      'title': title,
      'body': 'Сохранённая публикация',
      'created_at': '2026-11-27T03:00:00Z',
      'variant': 'imageOnly',
      'image_path': 'home-frame/$id.png',
    };

Map<String, dynamic> _promo(String id, String title,
        {required bool cover, bool saved = true, String? assetId}) =>
    {
      'id': id,
      'template_key': 'home_promo_v1',
      'schema_version': 2,
      'origin': 'admin',
      'placement': 'home_promo',
      if (saved) (cover ? '_offline_image' : '_offline_icon'): id,
      'payload': {
        'title': title,
        'subtitle': 'Объявление',
        'icon_key': 'psychology',
        'gradient_colors': ['#FFFBFF', '#F3EEF9'],
        'cta_label': 'Открыть',
        'dismissible': false,
        'card_variant': cover ? 'image_full' : 'compact_icon',
        'home_slot': cover ? 'after_news' : 'after_day_summary',
        (cover ? 'image_asset_id' : 'icon_asset_id'): assetId ?? id,
      },
    };

Future<Uint8List> _solidPng(int rgb) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Color(0xff000000 | rgb), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(240, 120);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

String _session(String owner) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return jsonEncode({
    'access_token': '${part({'alg': 'HS256'})}.${part({
          'iss': '$_project/auth/v1',
          'sub': owner,
          'session_id': owner == _owner
              ? '11111111-1111-4111-8111-111111111111'
              : '22222222-2222-4222-8222-222222222222',
          'aud': 'authenticated',
          'role': 'authenticated',
          'iat': now - 60,
          'exp': now + 3600,
        })}.fixture',
    'refresh_token': 'fixture-refresh-$owner',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': now + 3600,
    'user': {
      'id': owner,
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-01-01T00:00:00Z',
    },
  });
}

class _HomeFrameFixture {
  final holdNetwork = Completer<void>();
  final holdPromoMetadata = Completer<void>();
  final holdPromoMedia = Completer<void>();
  final events = StreamController<AuthState>.broadcast(sync: true);
  final requests = <String>[];
  late final Directory directory;
  late final Database contentDb;
  late final Database newsDb;
  late final NewsSqliteImageStore images;
  late final AuthSessionScope scope;
  late final SessionCapabilities capabilities;
  late final HomeContentCoordinator coordinator;
  late final HomeSnapshotCache projectCache;
  late final MockClient transport;
  SupabaseClient get client => Supabase.instance.client;

  HomeSnapshotCache cacheFor(String? project) => HomeSnapshotCache(
        currentUserId: () => scope.capture()?.userId,
        sessionGeneration: () => scope.generation,
        sessionIdentity: scope.capture,
        authScope: scope,
        project: project,
      );

  HomeDashboardService dashboard() => HomeDashboardService(
        client: client,
        sessionScope: scope,
        projectSnapshotCache: projectCache,
        publicImageCache: PublicNewsImageCache(openStore: () async => images),
      );

  Future<void> prepare() async {
    final articles = [_news('teal', 'Факультет'), _news('blue', 'Кампус')];
    SharedPreferences.setMockInitialValues({
      '${PublishedNewsCache.keyPrefix}__$_owner': jsonEncode(articles),
    });
    transport = MockClient((request) async {
      final path = request.url.path;
      requests.add(path);
      if (path.endsWith('/get_my_content_for_placement') &&
          client.auth.currentUser?.id == _owner) {
        await holdPromoMetadata.future;
        return http.Response(
          jsonEncode([
            _promo('hero', 'Новое объявление',
                cover: true, saved: false, assetId: 'new-hero'),
            _promo('shortcut', _shortcut, cover: false, saved: false),
          ]),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      if (path.endsWith('/content-media')) {
        await holdPromoMedia.future;
      } else {
        await holdNetwork.future;
      }
      return http.Response('simulated transport outage', 503, request: request);
    });
    await Supabase.initialize(
      url: _project,
      publishableKey: 'fixture-key',
      authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false, detectSessionInUri: false),
      httpClient: transport,
    );
    scope = AuthSessionScope(
      currentSession: () => client.auth.currentSession,
      authEvents: events.stream,
    );
    capabilities = SessionCapabilities(scope);
    await signIn(_owner);
    projectCache = cacheFor(_project);
    for (final cache in [cacheFor(null), projectCache]) {
      final ticket = cache.captureScope(_owner)!;
      final today = MskDate.today();
      final sections = {
        HomeSnapshotSection.profile: [
          {'id': _owner, 'name': _profileName, 'group_name': _group},
        ],
        HomeSnapshotSection.schedule: [
          {
            'id': 'lesson',
            'date': MskDate.isoDate(today),
            'week': 1,
            'day': 'ПН',
            'pair_num': 1,
            'time_start': '18:30',
            'time_end': '23:59',
            'subject': _lesson,
            'room': '4',
          },
        ],
        HomeSnapshotSection.assignments: [
          HomeSnapshotCodec.assignmentToMap(HomeAssignmentPreview(
            teamName: _lesson,
            assignment: Assignment(
              id: 'assignment',
              title: _assignment,
              description: 'Контрольный срок',
              dueAt: today.add(const Duration(days: 1)),
              published: true,
              votes: 1,
              completedByMe: false,
              createdBy: 'student',
              createdAt: today,
            ),
          )),
        ],
      };
      for (final section in sections.entries) {
        expect(
            await cache.write(
                scope: ticket,
                section: section.key,
                items: section.value,
                date: MskDate.isoDate(today),
                savedAt: DateTime.now()),
            isTrue);
      }
    }
    directory = await Directory.systemTemp.createTemp('student-home-frame-');
    newsDb = await databaseFactoryFfi.openDatabase('${directory.path}/news.db');
    images = NewsSqliteImageStore.forCollectionTest(
      database: newsDb,
      root: Directory('${directory.path}/news-images'),
    );
    final newsColors = [_teal, _blue];
    final savedNews = <Map<String, dynamic>>[];
    final savedNewsImages = <String, Uint8List>{};
    for (var index = 0; index < articles.length; index++) {
      final row = articles[index];
      final bytes = await _solidPng(newsColors[index]);
      final key = mapPublishedNews(row).imageCacheKey!;
      expect(await images.put(key, bytes, await images.capture(key)), isTrue);
      final imageRef = 'saved-${row['id']}';
      savedNews.add({...row, '_offline_image': imageRef});
      savedNewsImages[imageRef] = bytes;
    }
    contentDb = await openHomeContentSnapshotDatabase(
      '${directory.path}/content.db',
      factory: databaseFactoryFfi,
    );
    final store = HomeContentSnapshotStore(
      db: contentDb,
      scope: scope,
      currentBinding: () {
        final owner = scope.capture();
        return owner == null
            ? null
            : scope.bindingFor(owner, '$_project/auth/v1');
      },
      project: _project,
    );
    final content = {
      'news': HomeContentSnapshot(savedNews, savedNewsImages),
      'promo': HomeContentSnapshot(
        [
          _promo('hero', _hero, cover: true),
          _promo('shortcut', _shortcut, cover: false),
        ],
        {'hero': await _solidPng(_amber), 'shortcut': await _solidPng(_plum)},
      ),
    };
    for (final section in content.entries) {
      final ticket = await store.begin(section.key, isCurrent: () => true);
      expect(ticket, isNotNull);
      expect(await store.commit(ticket!, section.value), isTrue);
    }
    coordinator = HomeContentCoordinator(
        store: store, scope: scope, httpClient: transport);
  }

  Future<void> signIn(String owner) async {
    await client.auth.setInitialSession(_session(owner));
    events.add(AuthState(AuthChangeEvent.signedIn, client.auth.currentSession));
    expect(scope.capture()?.userId, owner);
  }

  Future<void> close() async {
    coordinator.dispose();
    capabilities.dispose();
    await events.close();
    await Supabase.instance.dispose();
    await newsDb.close();
    await contentDb.close();
    await directory.delete(recursive: true);
  }
}

typedef _Raster = ({String digest, Map<int, int> colors});

Future<_Raster> _renderFrame(
    WidgetTester tester, GlobalKey key, String name) async {
  final surface =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await surface.toImage(pixelRatio: 1);
    try {
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final colors = {_teal: 0, _blue: 0, _amber: 0, _plum: 0};
      for (var index = 0; index < bytes.length; index += 4) {
        final rgb =
            bytes[index] << 16 | bytes[index + 1] << 8 | bytes[index + 2];
        if (colors[rgb] case final count?) colors[rgb] = count + 1;
      }
      final capture = Platform.environment['STUDENT_FULL_HOME_CAPTURES'];
      if (capture != null) {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await Directory(capture).create(recursive: true);
        await File('$capture/$name.png').writeAsBytes(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
      }
      return (digest: sha256.convert(bytes).toString(), colors: colors);
    } finally {
      image.dispose();
    }
  }))!;
}

void _expectCompleteHome(_Raster raster, String frame) {
  final landmarks = {
    'owner greeting': find.textContaining(_profileName),
    'owner group': find.textContaining(_group),
    'schedule summary': find.text('Сводка дня'),
    'saved lesson': find.textContaining(_lesson).first,
    'assignments section': find.text('Ближайшие дела'),
    'saved assignment': find.text(_assignment),
    'saved hero': find.text(_hero),
    'saved shortcut': find.text(_shortcut),
  };
  final absent = [
    for (final landmark in landmarks.entries)
      if (landmark.value.hitTestable().evaluate().isEmpty) landmark.key,
  ];
  expect(absent, isEmpty,
      reason: '$frame visible Home landmarks, colors ${raster.colors}');
  expect(find.byType(StudentHomeNewsCard).hitTestable(), findsNWidgets(2));
  expect(raster.colors[_teal], greaterThan(5000),
      reason: '$frame news cover 1');
  expect(raster.colors[_blue], greaterThan(5000),
      reason: '$frame news cover 2');
  expect(raster.colors[_amber], greaterThan(12000),
      reason: '$frame promo cover');
  expect(raster.colors[_plum], greaterThan(60), reason: '$frame promo icon');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final text = FontLoader('packages/student_ui/WorkspaceSans')
      ..addFont(rootBundle
          .load('packages/student_ui/assets/fonts/NotoSans-Regular.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([text.load(), icons.load(), initializeDateFormatting()]);
  });
  if (Platform.isWindows) {
    open.overrideFor(
        OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
  }
  sqfliteFfiInit();

  for (final offline in [false, true]) {
    final mode = offline ? 'offline admission' : 'held network';
    testWidgets('$mode renders the complete saved Home before its first frame',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(440, 956);
      tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      final binding = tester.binding.defaultBinaryMessenger;
      const links = MethodChannel('com.llfbandit.app_links/events');
      binding.setMockMethodCallHandler(links, (_) async => null);
      addTearDown(() => binding.setMockMethodCallHandler(links, null));
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      final fixture = _HomeFrameFixture();
      await tester.runAsync(fixture.prepare);
      final capturedOwner = fixture.scope.capture()!;
      final barrier = OnlineSideEffectBarrier(
          ownerIsCurrent: () => fixture.scope.isCurrent(capturedOwner));
      OnlineSideEffectBarrier? nextBarrier;
      expect(
          fixture.capabilities.grant(
              offline
                  ? SessionCapabilityMode.cacheOnly
                  : SessionCapabilityMode.online,
              fixture.capabilities.beginAuthorization(capturedOwner)!),
          isTrue);
      final offlineReader = offline
          ? CachedHomeScheduleReader(
              capabilities: fixture.capabilities,
              home: fixture.projectCache,
              schedule: ScheduleMonthCache(fixture.scope, _project))
          : null;
      var dashboard = fixture.dashboard();
      final homeKey = GlobalKey();
      final rootKey = GlobalKey();
      final active = ValueNotifier<bool>(true);
      Widget app(Widget child) => AuthSessionScopeHost(
            key: rootKey,
            createScope: () => fixture.scope,
            child: MaterialApp(
              theme:
                  ProductTheme.build().copyWith(platform: TargetPlatform.iOS),
              debugShowCheckedModeBanner: false,
              home: child,
            ),
          );
      Widget tabs(Widget home) => ValueListenableBuilder<bool>(
            valueListenable: active,
            child: home,
            builder: (context, showingHome, child) => Scaffold(
              body: IndexedStack(index: showingHome ? 0 : 1, children: [
                RepaintBoundary(
                  key: homeKey,
                  child: ColoredBox(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: child!,
                  ),
                ),
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
          );
      Future<void> open(OnlineSideEffectBarrier online) async {
        await tester.pumpWidget(app(tabs(HomeScreen(
          dashboardService: dashboard,
          cachedReader: offlineReader,
          onlineBarrier: offline ? null : online,
          homeContent: fixture.coordinator,
          homeContentCapabilities: offline ? fixture.capabilities : null,
          activeListenable: active,
        ))));
        final home = find.byType(StudentHomeView);
        for (var spin = 0; home.evaluate().isEmpty && spin < 180; spin++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        expect(home, findsOneWidget,
            reason: 'Home must paint while transport is held');
      }

      final name = offline ? 'offline' : 'slow-network';
      try {
        await open(barrier);
        // Stop at the first content frame rather than awaiting any animation
        // or image stream. Sample the whole viewport before the first assertion.
        final first = await _renderFrame(tester, homeKey, '$name-home-first');
        _expectCompleteHome(first, '$name first frame');
        expect(fixture.holdNetwork.isCompleted, isFalse);
        if (offline) {
          expect(fixture.requests, isEmpty);
        } else {
          expect(
              fixture.requests, contains('/rest/v1/rpc/get_my_published_news'));
        }

        await tester.pump(const Duration(milliseconds: 400));
        final settled =
            await _renderFrame(tester, homeKey, '$name-home-settled');
        _expectCompleteHome(settled, '$name settled frame');
        expect(settled.digest, first.digest,
            reason: 'No pixels may be added after the opening frame');
        await tester.tap(find.text('Профиль'));
        await tester.pump();
        expect(find.text('Другая вкладка'), findsOneWidget);
        await tester.tap(find.text('Главная'));
        await tester.pump();
        final returned =
            await _renderFrame(tester, homeKey, '$name-home-tab-return');
        _expectCompleteHome(returned, '$name tab return');
        expect(returned.digest, first.digest,
            reason: 'Tab return paints the entire same viewport');

        if (!offline) {
          fixture.holdPromoMetadata.complete();
          const mediaPath = '/functions/v1/content-media';
          for (var frame = 0;
              !fixture.requests.contains(mediaPath) && frame < 180;
              frame++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 5)));
            await tester.pump();
          }
          expect(fixture.requests, contains(mediaPath));
          final refreshing = await _renderFrame(
              tester, homeKey, 'slow-network-home-replacement-pending');
          expect(refreshing.digest, first.digest,
              reason:
                  'New promo metadata may not remove the saved cover and icon while media is pending');
          fixture.holdPromoMedia.complete();
          barrier.close();

          await tester.pumpWidget(app(const SizedBox.shrink()));
          dashboard.dispose();
          await tester.runAsync(() => fixture.signIn(_otherOwner));
          dashboard = fixture.dashboard();
          final newOwner = fixture.scope.capture()!;
          final cleanBarrier = OnlineSideEffectBarrier(
              ownerIsCurrent: () => fixture.scope.isCurrent(newOwner));
          nextBarrier = cleanBarrier;
          await open(cleanBarrier);
          final clean =
              await _renderFrame(tester, homeKey, 'new-account-home-first');
          expect(clean.colors.values, everyElement(0));
          expect(find.textContaining(_profileName), findsNothing);
          expect(find.textContaining(_group), findsNothing);
          expect(find.text(_assignment), findsNothing);
          expect(find.text(_hero), findsNothing);
          expect(find.text(_shortcut), findsNothing);
          cleanBarrier.close();
        }
      } finally {
        barrier.close();
        nextBarrier?.close();
        dashboard.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        active.dispose();
        fixture.holdNetwork.complete();
        if (!fixture.holdPromoMetadata.isCompleted)
          fixture.holdPromoMetadata.complete();
        if (!fixture.holdPromoMedia.isCompleted)
          fixture.holdPromoMedia.complete();
        await tester.pump(const Duration(seconds: 20));
        for (var turn = 0;
            (barrier.activeCount != 0 || (nextBarrier?.activeCount ?? 0) != 0) &&
                turn < 180;
            turn++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        expect(barrier.activeCount + (nextBarrier?.activeCount ?? 0), 0);
        // Let FFI transaction continuations queued in the widget zone finish
        // while the file handles close, instead of blocking that zone in runAsync.
        var closed = false;
        Object? closeError;
        unawaited(fixture.close().then((_) => closed = true,
            onError: (Object error, StackTrace _) {
          closeError = error;
          closed = true;
        }));
        for (var turn = 0; !closed && turn < 180; turn++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
        expect(closed, isTrue);
        expect(closeError, isNull);
      }
    });
  }
}
