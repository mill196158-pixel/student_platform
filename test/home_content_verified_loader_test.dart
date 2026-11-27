import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';
import 'package:student_platform/src/config/supabase_config.dart';
import 'package:student_platform/src/core/auth_session_scope.dart';
import 'package:student_platform/src/core/online_side_effect_barrier.dart';
import 'package:student_platform/src/core/offline_policy_grant.dart';
import 'package:student_platform/src/core/session_capabilities.dart';
import 'package:student_platform/src/ui/home/home_content_coordinator.dart';
import 'package:student_platform/src/ui/home/home_promo_service.dart';
import 'package:student_platform/src/ui/info/home_content_snapshot_store.dart';
import 'package:student_platform/src/ui/home/home_content_verified_loader.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';
import 'package:student_platform/src/ui/home/news_sqlite_image_store.dart';
import 'package:student_platform/src/ui/home/public_news_image_cache.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Storage extends LocalStorage {
  _Storage(this.raw);
  String? raw;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => raw != null;
  @override
  Future<String?> accessToken() async => raw;
  @override
  Future<void> persistSession(String value) async => raw = value;
  @override
  Future<void> removePersistedSession() async => raw = null;
}


class _DelayedDenyStore implements HomeContentSnapshotStore {
  _DelayedDenyStore(this.inner);
  final HomeContentSnapshotStore inner;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<HomeContentTicket?> begin(String section,
          {required bool Function() isCurrent}) =>
      inner.begin(section, isCurrent: isCurrent);
  @override
  Future<bool> commit(HomeContentTicket ticket, HomeContentSnapshot value) =>
      inner.commit(ticket, value);
  @override
  Future<bool> deny(HomeContentTicket ticket) async {
    entered.complete();
    await release.future;
    return inner.deny(ticket);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

String _session() {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final token = '${part({'alg': 'HS256'})}.${part({
        'iss': '${SupabaseConfig.url}/auth/v1',
        'sub': 'qa',
        'session_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'aud': 'authenticated',
        'role': 'authenticated',
        'iat': now - 60,
        'exp': now + 3600
      })}.signature';
  return jsonEncode({
    'access_token': token,
    'refresh_token': 'synthetic',
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': now + 3600,
    'user': {
      'id': 'qa',
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-01-01T00:00:00Z'
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AuthSessionScope scope;
  late OnlineSideEffectBarrier barrier;
  late http.Client transport;
  late Future<http.Response> Function(http.Request) handler;
  var denials = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    denials = 0;
    transport = MockClient((request) => handler(request));
    await Supabase.initialize(
        url: SupabaseConfig.url,
        publishableKey: 'qa',
        httpClient: transport,
        authOptions: FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: _Storage(_session())));
    final client = Supabase.instance.client;
    scope = AuthSessionScope(
        currentSession: () => client.auth.currentSession,
        authEvents: client.auth.onAuthStateChange);
    await scope.ready;
    barrier =
        OnlineSideEffectBarrier(ownerIsCurrent: () => scope.capture() != null);
  });
  tearDown(() async {
    scope.dispose();
    await Supabase.instance.dispose();
  });
  HomeContentVerifiedLoader loader({SupabaseClient? client, Uri? project}) =>
      HomeContentVerifiedLoader(
          client: client ?? Supabase.instance.client,
          httpClient: transport,
          scope: scope,
          owner: scope.capture()!,
          barrier: barrier,
          project: project ?? Uri.parse(SupabaseConfig.url),
          onAuthorizationDenial: () async {
            denials++;
          });
  http.Response jsonResponse(http.Request req, Object value,
          [int code = 200]) =>
      http.Response(jsonEncode(value), code,
          headers: {'content-type': 'application/json'}, request: req);
  final news = [
    {
      'id': 'id',
      'title': 'News',
      'created_at': '2026-11-06T00:00:00Z',
      'variant': 'imageOverlay',
      'image_path': 'private/path',
      'unexpected_secret': 'remove'
    }
  ];

  test('only authorised bytes and sanitized rows are returned', () async {
    handler = (request) async {
      if (request.url.path.contains('/rpc/'))
        return jsonResponse(request, news);
      if (request.url.path.contains('/functions/'))
        return jsonResponse(
            request, {'signedUrl': '${SupabaseConfig.url}/file?token=secret'});
      return http.Response.bytes([1, 2, 3], 200, request: request);
    };
    final result = await loader().load(HomeContentSection.news);
    expect(result.status, HomeContentLoadStatus.confirmed);
    expect(result.rows.single['image_path'], 'private/path');
    expect(jsonEncode(result.rows), isNot(contains('secret')));
    expect(result.media[result.rows.single['_offline_image']], [1, 2, 3]);
  });

  test('promo keeps the verified saved frame until a replacement is ready',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('home-promo-frame-');
    final db = await openHomeContentSnapshotDatabase('${dir.path}/content.db',
        factory: databaseFactoryFfi);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
    final store = HomeContentSnapshotStore(
        db: db,
        scope: scope,
        currentBinding: () => OfflineSessionBinding.fromSession(
            Supabase.instance.client.auth.currentSession!,
            '${SupabaseConfig.url}/auth/v1'),
        project: SupabaseConfig.url);
    final coordinator = HomeContentCoordinator(
        store: store, scope: scope, httpClient: transport);
    addTearDown(coordinator.dispose);
    var currentTitle = 'Saved promo';
    var includeRemoved = true;
    var mediaUnavailable = false;
    var deny = false;
    var requestsForMedia = 0;
    Map<String, dynamic> row(String id, String title) => {
          'id': id,
          'template_key': 'home_promo_v1',
          'schema_version': 2,
          'placement': 'home_promo',
          'origin': 'admin',
          'payload': {
            'title': title,
            'subtitle': 'Text',
            'icon_key': 'psychology',
            'gradient_colors': ['#FFFFFF', '#123456'],
            'cta_label': 'Open',
            'cta_route': '/my-diary',
            'dismissible': true,
            'card_variant': 'image_full',
            'image_asset_id': 'image-a',
            'icon_asset_id': 'icon-a',
          },
        };
    handler = (request) async {
      if (request.url.path.contains('/rpc/')) {
        if (deny) {
          return jsonResponse(request,
              {'code': '42501', 'message': 'placement denied'}, 403);
        }
        return jsonResponse(request, [
          row('promo-id', currentTitle),
          if (includeRemoved) row('old-id', 'Removed promo'),
        ]);
      }
      if (request.url.path.contains('/functions/')) {
        requestsForMedia++;
        if (mediaUnavailable) return http.Response('unavailable', 503);
        final id = (jsonDecode(request.body) as Map)['assetId'];
        return jsonResponse(
            request, {'signedUrl': '${SupabaseConfig.url}/file/$id'});
      }
      return http.Response.bytes(
          request.url.path.endsWith('icon-a') ? [2] : [1], 200,
          request: request);
    };

    final live = await coordinator.refreshPromo(barrier);
    expect(live?.promo.card?.homePromo.ctaRoute, '/my-diary');
    expect(live?.images['promo-id'], [1]);
    expect(live?.icons['promo-id'], [2]);
    final saved = await coordinator.readOnline('promo', barrier);
    expect(saved, isNotNull);
    expect(requestsForMedia, 4, reason: 'first snapshot read is disk only');
    final onDisk = PreparedHomePromos.fromSnapshot(saved!);
    expect(onDisk?.promo.card?.homePromo.title, currentTitle);
    expect(onDisk?.promo.card?.homePromo.ctaRoute, isNull);
    expect(onDisk?.images['promo-id'], [1]);

    currentTitle = 'Replacement';
    final entered = Completer<void>();
    final candidateReady = Completer<PreparedHomePromos?>();
    final reload = coordinator.refreshPromo(barrier, prepare: (candidate) {
      expect(candidate.promo.card?.homePromo.title, 'Replacement');
      entered.complete();
      return candidateReady.future;
    });
    await entered.future;
    expect((await coordinator.readOnline('promo', barrier))!.rows, saved.rows);
    candidateReady.complete(null);
    expect(await reload, isNull);
    expect((await coordinator.readOnline('promo', barrier))!.rows, saved.rows);

    includeRemoved = false;
    mediaUnavailable = true;
    final mediaBefore = requestsForMedia;
    Set<String>? confirmed;
    expect(await coordinator.refreshPromo(barrier, onVisibleIds: (ids) {
      expect(requestsForMedia, mediaBefore, reason: 'removal precedes download');
      confirmed = ids;
    }), isNull);
    expect(confirmed, {'promo-id'});
    final pruned = await coordinator.readOnline('promo', barrier);
    expect(pruned?.rows, [saved.rows.first]);
    expect(pruned?.images.length, 2);
    expect(PreparedHomePromos.fromSnapshot(pruned!)?.images['promo-id'], [1]);

    final closed = OnlineSideEffectBarrier(ownerIsCurrent: () => true)..close();
    expect(await coordinator.readOnline('promo', closed), isNull);
    deny = true;
    expect(await coordinator.refreshPromo(barrier), isNull);
    expect(coordinator.isDenied('promo'), isTrue);
    expect(await store.readOnline('promo', barrier), isNull);
    expect(await coordinator.readOnline('promo', barrier), isNull);
  });
  test('rejects wrong client and project before any requests', () async {
    var calls = 0;
    handler = (r) async {
      calls++;
      return jsonResponse(r, []);
    };
    final other =
        SupabaseClient('https://other.test', 'qa', httpClient: transport);
    expect((await loader(client: other).load(HomeContentSection.news)).status,
        HomeContentLoadStatus.unavailable);
    expect(
        (await loader(project: Uri.parse('https://other.test'))
                .load(HomeContentSection.news))
            .status,
        HomeContentLoadStatus.unavailable);
    expect(calls, 0);
    other.dispose();
  });
  test('foreign signed URL and Storage 403 are unavailable', () async {
    var foreign = true;
    handler = (r) async {
      if (r.url.path.contains('/rpc/')) return jsonResponse(r, news);
      if (r.url.path.contains('/functions/'))
        return jsonResponse(r, {
          'signedUrl':
              foreign ? 'https://other.test/file' : '${SupabaseConfig.url}/file'
        });
      return http.Response('', 403, request: r);
    };
    expect((await loader().load(HomeContentSection.news)).status,
        HomeContentLoadStatus.unavailable);
    foreign = false;
    expect((await loader().load(HomeContentSection.news)).status,
        HomeContentLoadStatus.unavailable);
    expect(denials, 0);
  });
  test('late edge denial is persisted before closed barrier drains', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    handler = (r) async {
      if (r.url.path.contains('/rpc/')) return jsonResponse(r, news);
      entered.complete();
      await release.future;
      return jsonResponse(r, {}, 403);
    };
    final pending = loader().load(HomeContentSection.news);
    await entered.future;
    barrier.close();
    release.complete();
    await pending;
    expect(denials, 1);
    expect(barrier.activeCount, 0);
  });

  test('online warm survives SQLite reopen and validates offline cover',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('home_content_chain_');
    final path = '${dir.path}/content.db';
    var db = await openHomeContentSnapshotDatabase(path,
        factory: databaseFactoryFfi);
    OfflineSessionBinding? binding() => OfflineSessionBinding.fromSession(
        Supabase.instance.client.auth.currentSession!,
        '${SupabaseConfig.url}/auth/v1');
    HomeContentSnapshotStore store() => HomeContentSnapshotStore(
        db: db,
        scope: scope,
        currentBinding: binding,
        project: SupabaseConfig.url);
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/afoAAAAASUVORK5CYII=');
    handler = (r) async {
      if (r.url.path.contains('/rpc/')) return jsonResponse(r, news);
      if (r.url.path.contains('/functions/'))
        return jsonResponse(r, {'signedUrl': '${SupabaseConfig.url}/file'});
      return http.Response.bytes(png, 200, request: r);
    };
    await HomeContentCoordinator(
            store: store(), scope: scope, httpClient: transport)
        .warm(HomeContentSection.news, barrier);
    await db.close();
    db = await openHomeContentSnapshotDatabase(path,
        factory: databaseFactoryFfi);
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    final snapshot = await store().read('news', caps);
    expect(snapshot?.rows.single['title'], 'News');
    expect(snapshot?.images[snapshot.rows.single['_offline_image']], png);
    expect(snapshot!.rows.single['image_path'], 'private/path');
    final imageDb = await databaseFactoryFfi.openDatabase('${dir.path}/images.db');
    final imageStore = NewsSqliteImageStore(database: imageDb,
        root: Directory('${dir.path}/images'));
    final cache = PublicNewsImageCache(openStore: () async => imageStore);
    final service = HomeDashboardService(client: Supabase.instance.client,
        publicImageCache: cache, httpClient: transport);
    final row = snapshot.rows.single;
    final item = mapPublishedNews(row).copyWith(
        imageBytes: snapshot.images[row['_offline_image']]);
    expect((await service.validateNewsImages([item])).single.imageBytes, png);
    final noPath = Map<String, dynamic>.from(row)..remove('image_path');
    final old = mapPublishedNews(noPath).copyWith(imageBytes: item.imageBytes);
    expect((await service.validateNewsImages([old])).single.imageBytes, isNull);
    await cache.invalidate(item.imagePath);
    expect((await service.validateNewsImages([item])).single.imageBytes, isNull);
    service.dispose();
    await imageDb.close();
    caps.block();
    expect(await store().read('news', caps), isNull);
    caps.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  test('success cannot uncover content while a late denial is still pending',
      () async {
    if (Platform.isWindows) {
      open.overrideFor(
          OperatingSystem.windows, () => DynamicLibrary.open('winsqlite3.dll'));
    }
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('home_content_race_');
    final db = await openHomeContentSnapshotDatabase('${dir.path}/content.db',
        factory: databaseFactoryFfi);
    OfflineSessionBinding? binding() => OfflineSessionBinding.fromSession(
        Supabase.instance.client.auth.currentSession!,
        '${SupabaseConfig.url}/auth/v1');
    final inner = HomeContentSnapshotStore(
        db: db,
        scope: scope,
        currentBinding: binding,
        project: SupabaseConfig.url);
    final delayed = _DelayedDenyStore(inner);
    final coordinator = HomeContentCoordinator(
        store: delayed, scope: scope, httpClient: transport);
    var edgeCalls = 0;
    handler = (r) async {
      if (r.url.path.contains('/rpc/')) return jsonResponse(r, news);
      if (r.url.path.contains('/functions/')) {
        edgeCalls++;
        return edgeCalls == 1
            ? jsonResponse(r, {}, 403)
            : jsonResponse(r, {'signedUrl': '${SupabaseConfig.url}/file'});
      }
      return http.Response.bytes([1, 2, 3], 200, request: r);
    };
    final deniedWarm = coordinator.warm(HomeContentSection.news, barrier);
    await delayed.entered.future;
    expect(coordinator.isDenied('news'), true);
    await coordinator.warm(HomeContentSection.news, barrier);
    expect(coordinator.isDenied('news'), true);
    delayed.release.complete();
    await deniedWarm;
    expect(coordinator.isDenied('news'), true);
    final caps = SessionCapabilities(scope);
    expect(
        caps.grant(SessionCapabilityMode.cacheOnly,
            caps.beginAuthorization(scope.capture()!)!),
        true);
    expect(await inner.read('news', caps), isNull);
    caps.dispose();
    coordinator.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });
}
