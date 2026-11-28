import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/auth_session_scope_host.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/chats/core/project_chat_server_cache.dart';
import 'package:student_platform/src/ui/home/cached_home_schedule_reader.dart';
import 'package:student_platform/src/ui/home/home_snapshot_cache.dart';
import 'package:student_platform/src/ui/profile/profile_avatar_image.dart';
import 'package:student_platform/src/ui/profile/profile_screen.dart';
import 'package:student_platform/src/ui/schedule/schedule_month_cache.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _project = SupabaseConfig.url;
const _a = '82177b25-8dc2-4dc1-9e16-d3797bf65410';
const _b = '093a7e1a-cc42-42e8-ab9a-fe4195c21572';
const _nameA = 'Синтетический профиль А';
const _nameB = 'Синтетический профиль Б';
const _colorA = Color(0xffcf2a71);
const _colorB = Color(0xff167848);
const _colorReplacement = Color(0xff176bc0);

class _NoProductionSockets extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = ((_) {
          attempts++;
          return 'PROXY 127.0.0.1:1';
        });
}

class _OfflineChats implements ProjectChatServerCache {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _profile(String owner, String? url) => {
      'id': owner,
      'login': 'profile-fixture',
      'name': owner == _a ? _nameA : _nameB,
      'surname': '',
      'university': 'СПбГАСУ',
      'group_name': 'QA-01',
      'status': 'Тест iOS',
      'avatar_url': url,
    };

String _session(String owner) {
  String encode(Map<String, Object> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final claims = encode({
    'iss': '$_project/auth/v1',
    'sub': owner,
    'session_id': owner,
    'aud': 'authenticated',
    'role': 'authenticated',
    'iat': expires - 3660,
    'exp': expires,
  });
  return jsonEncode({
    'access_token': '${encode({'alg': 'HS256'})}.$claims.fixture',
    'refresh_token': 'fixture-$owner',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': expires,
    'user': {'id': owner, 'aud': 'authenticated', 'created_at': '2026-01-01'},
  });
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(88, 88);
  try {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<Uint8List> _seedAvatar(String owner, String url, Color color) async {
  final manager = DefaultCacheManager();
  final provider = profileAvatarImage(owner, url) as CachedNetworkImageProvider;
  final bytes = await _solidPng(color);
  await manager.putFile(url, bytes,
      key: provider.cacheKey, fileExtension: 'png');
  final deadline = Stopwatch()..start();
  while (deadline.elapsed < const Duration(seconds: 2)) {
    final saved =
        await readSavedProfileAvatar(owner, url, isCurrent: () => true);
    if (saved != null) {
      expect(saved, orderedEquals(bytes));
      return bytes;
    }
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  throw TestFailure('Synthetic photo did not reach app-owned iOS cache');
}

void _clearDecodedPhotos() {
  final cache = PaintingBinding.instance.imageCache;
  cache.clear();
  cache.clearLiveImages();
}

Future<void> _raster(WidgetTester tester, GlobalKey boundary, String name,
    {Color? expected, Color? forbidden}) async {
  final paint =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final avatar = find.descendant(
      of: find.byType(StudentProfileScreenPreview),
      matching: find.byType(CircleAvatar));
  final image = await paint.toImage(pixelRatio: 1);
  try {
    final docs = await getApplicationDocumentsDirectory();
    final folder = await Directory('${docs.path}/profile-qa').create();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('${folder.path}/$name.png').writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
    if (expected != null || forbidden != null) {
      expect(avatar, findsOneWidget);
      final center = paint.globalToLocal(tester.getCenter(avatar));
      final rgba =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int count(Color color) {
        var hits = 0;
        for (var y = center.dy.round() - 9; y <= center.dy.round() + 9; y++) {
          for (var x = center.dx.round() - 9; x <= center.dx.round() + 9; x++) {
            final p = (y * image.width + x) * 4;
            if ((rgba.getUint8(p) - (color.r * 255).round()).abs() <= 8 &&
                (rgba.getUint8(p + 1) - (color.g * 255).round()).abs() <= 8 &&
                (rgba.getUint8(p + 2) - (color.b * 255).round()).abs() <= 8) {
              hits++;
            }
          }
        }
        return hits;
      }

      if (expected != null) {
        expect(count(expected), greaterThan(300),
            reason: '$name must already contain saved avatar pixels');
      }
      if (forbidden != null) {
        expect(count(forbidden), 0,
            reason: '$name must not contain the old avatar');
      }
    }
  } finally {
    image.dispose();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  if (!Platform.isIOS) return;

  final socketGuard = _NoProductionSockets();
  HttpOverrides.global = socketGuard;
  tearDownAll(() => HttpOverrides.global = null);

  for (final mode in ['slow-online', 'offline', 'clean-no-avatar']) {
    final offline = mode == 'offline';
    final noAvatar = mode == 'clean-no-avatar';
    testWidgets('iOS profile first frame, return and reconstruction: $mode',
        (tester) async {
      final url =
          '$_project/storage/v1/object/public/avatars/$_a/profile-qa-$mode.png?v=${DateTime.now().microsecondsSinceEpoch}';
      final rowA = _profile(_a, noAvatar ? null : url);
      var rowB =
          _profile(_b, url); // Deliberately same URL, different owner key.
      SharedPreferences.setMockInitialValues({'user': jsonEncode(rowA)});
      if (!noAvatar) {
        await _seedAvatar(_a, url, _colorA);
        if (!offline) await _seedAvatar(_b, url, _colorB);
      }
      _clearDecodedPhotos();
      final hold = Completer<void>();
      final oldRefresh = Completer<void>();
      final releaseOld = Completer<void>();
      final requests = <String>[];
      final socketStart = socketGuard.attempts;
      final transport = MockClient((request) async {
        final path = request.url.path;
        requests.add(path);
        if (path == '/rest/v1/users') {
          switch (request.url.queryParameters['id']) {
            case 'eq.$_a':
              if (!oldRefresh.isCompleted) oldRefresh.complete();
              await releaseOld.future;
              return http.Response(jsonEncode([rowA]), 200,
                  request: request,
                  headers: {'content-type': 'application/json'});
            case 'eq.$_b':
              return http.Response(jsonEncode([rowB]), 200,
                  request: request,
                  headers: {'content-type': 'application/json'});
          }
        }
        await hold.future;
        return http.Response('fixture request blocked', 503, request: request);
      });
      await Supabase.initialize(
          url: _project,
          publishableKey: 'fixture-key',
          httpClient: transport,
          authOptions: const FlutterAuthClientOptions(
              autoRefreshToken: false,
              detectSessionInUri: false,
              localStorage: EmptyLocalStorage()));
      final client = Supabase.instance.client;
      await client.auth.setInitialSession(_session(_a));
      final scope = AuthSessionScope(
          currentSession: () => client.auth.currentSession,
          authEvents: client.auth.onAuthStateChange);
      await scope.ready.timeout(const Duration(seconds: 3));
      final owner = scope.capture()!;
      final caps = SessionCapabilities(scope);
      final active = ValueNotifier(true);
      final boundary = GlobalKey();
      final profileKey = ValueNotifier(0);
      expect(
          caps.grant(
              offline
                  ? SessionCapabilityMode.cacheOnly
                  : SessionCapabilityMode.online,
              caps.beginAuthorization(owner)!),
          isTrue);
      CachedHomeScheduleReader? reader;
      if (offline) {
        final home = HomeSnapshotCache(
            project: _project,
            authScope: scope,
            currentUserId: () => scope.capture()?.userId,
            sessionGeneration: () => scope.generation,
            sessionIdentity: scope.capture);
        expect(
            await home.write(
                scope: home.captureScope(_a)!,
                section: HomeSnapshotSection.profile,
                items: [rowA],
                savedAt: DateTime.now()),
            isTrue);
        reader = CachedHomeScheduleReader(
            capabilities: caps,
            home: home,
            schedule: ScheduleMonthCache(scope, _project));
      }
      final chats = offline ? _OfflineChats() : null;
      final area = find.byType(StudentProfileScreenPreview);
      final avatar =
          find.descendant(of: area, matching: find.byType(CircleAvatar));

      Future<void> until(bool Function() ready, String reason) async {
        final time = Stopwatch()..start();
        while (!ready() && time.elapsed < const Duration(seconds: 6)) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(ready(), isTrue, reason: reason);
      }

      Future<void> firstProfile(String name, String status, Color color) async {
        await until(
            () => area.evaluate().isNotEmpty, '$status mounts saved profile');
        expect(find.text(name), findsOneWidget);
        await _raster(tester, boundary, '$mode-$status', expected: color);
        debugPrint('IOS_PROFILE_FRAME $mode $status avatar=true');
      }

      try {
        await tester.pumpWidget(RepaintBoundary(
            key: boundary,
            child: AuthSessionScopeHost(
                createScope: () => scope,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: ProductTheme.build(),
                  home: ValueListenableBuilder<bool>(
                      valueListenable: active,
                      builder: (_, visible, profile) => Scaffold(
                            body: IndexedStack(
                                index: visible ? 0 : 1,
                                children: [
                                  profile!,
                                  const Center(child: Text('Другой раздел'))
                                ]),
                            bottomNavigationBar: SafeArea(
                                top: false,
                                child: Row(children: [
                                  TextButton(
                                      onPressed: () => active.value = false,
                                      child: const Text('Главная')),
                                  TextButton(
                                      onPressed: () => active.value = true,
                                      child: const Text('Профиль')),
                                ])),
                          ),
                      child: ValueListenableBuilder(
                          valueListenable: profileKey,
                          builder: (_, revision, __) => ProfileScreen(
                              key: ValueKey(revision),
                              activeListenable: active,
                              cachedReader: reader,
                              cachedChats: chats,
                              cachedCapabilities: offline ? caps : null))),
                ))));
        if (noAvatar) {
          await until(() => area.evaluate().isNotEmpty,
              'Saved profile without a photo mounts');
          expect(find.text(_nameA), findsOneWidget);
          final placeholder = tester.widget<CircleAvatar>(avatar);
          expect(placeholder.backgroundImage, isNull);
          expect(placeholder.foregroundImage, isNull);
          await _raster(tester, boundary, '$mode-initial', forbidden: _colorA);
          expect(hold.isCompleted, isFalse);
          expect(socketGuard.attempts, socketStart);
          debugPrint('IOS_PROFILE_NO_AVATAR_FIRST_FRAME_OK');
          return;
        }
        await firstProfile(_nameA, 'initial', _colorA);
        expect(hold.isCompleted, isFalse);
        await tester.tap(find.text('Главная'));
        await tester.pump();
        expect(find.text('Другой раздел'), findsOneWidget);
        await tester.tap(find.text('Профиль'));
        await tester.pump();
        await _raster(tester, boundary, '$mode-tab-return', expected: _colorA);

        // Reconstruct Profile while hidden, with a cold Flutter image cache.
        await tester.tap(find.text('Главная'));
        await tester.pump();
        _clearDecodedPhotos();
        profileKey.value++;
        await tester.pump();
        final hidden =
            find.byType(StudentProfileScreenPreview, skipOffstage: false);
        await until(() => hidden.evaluate().isNotEmpty,
            'Hidden reconstructed profile becomes ready');
        await tester.tap(find.text('Профиль'));
        await tester.pump();
        await _raster(tester, boundary, '$mode-cold-return', expected: _colorA);
        debugPrint('IOS_PROFILE_FRAME $mode cold-return avatar=true');

        if (offline) {
          expect(requests, isEmpty);
          caps.block();
          await tester.pump();
          expect(find.text(_nameA), findsNothing);
          expect(avatar, findsNothing);
          expect(find.text('Сохранённый профиль недоступен.'), findsOneWidget);
          await _raster(tester, boundary, '$mode-revoked');
        } else {
          await tester.tap(find.byTooltip('Обновить'));
          await until(
              () => oldRefresh.isCompleted, 'Old owner refresh is held');
          await client.auth.setInitialSession(_session(_b));
          await tester.pump();
          expect(find.text(_nameA), findsNothing,
              reason: 'Switch drops prior owner immediately');
          await until(() => find.text(_nameB).evaluate().isNotEmpty,
              'New owner loaded independently');
          await _raster(tester, boundary, '$mode-switched',
              expected: _colorB, forbidden: _colorA);
          releaseOld.complete();
          await tester.pump(const Duration(milliseconds: 64));
          expect(find.text(_nameA), findsNothing);
          await _raster(tester, boundary, '$mode-late-old-response',
              expected: _colorB, forbidden: _colorA);
          final replacement = url
              .replaceFirst('$_a/', '$_b/')
              .replaceFirst('.png', '-replacement.png');
          final newBytes =
              await _seedAvatar(_b, replacement, _colorReplacement);
          rowB = _profile(_b, replacement);
          await tester.tap(find.byTooltip('Обновить'));
          await until(() {
            if (avatar.evaluate().isEmpty) return false;
            final model = tester.widget<CircleAvatar>(avatar);
            final provider = model.foregroundImage ?? model.backgroundImage;
            return switch (provider) {
              final MemoryImage image => listEquals(image.bytes, newBytes),
              final CachedNetworkImageProvider image =>
                image.url == replacement,
              _ => false,
            };
          }, 'An updated profile points at its new decoded photo');
          await _raster(tester, boundary, '$mode-replaced',
              expected: _colorReplacement, forbidden: _colorB);
          rowB = _profile(_b, null);
          await tester.tap(find.byTooltip('Обновить'));
          await until(() {
            if (avatar.evaluate().isEmpty) return false;
            final model = tester.widget<CircleAvatar>(avatar);
            return model.foregroundImage == null &&
                model.backgroundImage == null;
          }, 'Authoritative removal clears both image providers');
          expect(find.text(_nameB), findsOneWidget);
          await _raster(tester, boundary, '$mode-deleted',
              forbidden: _colorReplacement);
          debugPrint(
              'IOS_PROFILE_ACCOUNT_ISOLATION_REPLACEMENT_AND_REMOVAL_OK');
        }
        expect(socketGuard.attempts, socketStart,
            reason:
                'Native image loader must not attempt network for a saved avatar');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!releaseOld.isCompleted) releaseOld.complete();
        hold.complete();
        active.dispose();
        profileKey.dispose();
        caps.dispose();
        await Supabase.instance.dispose();
        transport.close();
      }
    });
  }
}
