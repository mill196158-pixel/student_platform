import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';

class SlowDisk extends NewsImageDiskCache {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<Uint8List?> peek(NewsImageCacheKey key) async => null;
  @override
  Future<void> pruneOtherVersions(String path, String keepVersion) async {}
  @override
  Future<void> put(NewsImageCacheKey key, Uint8List bytes) async {
    entered.complete();
    await release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('switch while preferences load cannot start another user request',
      () async {
    var uid = 'a';
    final prefs = Completer<SharedPreferences>();
    final service = ContentMediaService(
        currentUserId: () => uid, prefs: () => prefs.future);
    final result = service.resolveDownload('asset');
    uid = 'b';
    prefs.complete(await SharedPreferences.getInstance());
    expect(await result, isNull);
  });
  test('switch while signed URL RPC waits cannot persist or return old grant',
      () async {
    var uid = 'a';
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    final client = SupabaseClient('https://example.com', 'public-test-key',
        httpClient: MockClient((_) {
      entered.complete();
      return response.future;
    }));
    final service =
        ContentMediaService(client: client, currentUserId: () => uid);
    final result = service.resolveDownload('asset');
    await entered.future;
    uid = 'b';
    response.complete(http.Response(
        jsonEncode(
            {'signedUrl': 'https://example.com/image', 'expiresIn': 3600}),
        200,
        headers: {'content-type': 'application/json'}));
    expect(await result, isNull);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    await client.dispose();
  });
  test('clearAsset while authorization is pending prevents old results', () async {
    final entered = Completer<void>();
    final response = Completer<http.Response>();
    final client = SupabaseClient('https://example.com', 'public-test-key',
        httpClient: MockClient((_) {
      entered.complete();
      return response.future;
    }));
    addTearDown(client.dispose);
    final service = ContentMediaService(client: client, currentUserId: () => 'a');
    final result = service.fetchBytes('asset', contentVersion: 'v1');
    await entered.future;
    await service.clearAsset('asset', contentVersion: 'v1');
    response.complete(http.Response(
        jsonEncode({'signedUrl': 'https://example.com/image', 'expiresIn': 3600}),
        200, headers: {'content-type': 'application/json'}));
    expect(await result, isNull);
  });
  test('switch during disk write cannot return bytes to the new account',
      () async {
    var uid = 'a';
    final disk = SlowDisk();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'content_media_url_v2__a|asset',
        jsonEncode({
          'signedUrl': 'https://example.com/image',
          'expiresAt':
              DateTime.now().add(const Duration(minutes: 10)).toIso8601String(),
        }));
    final service = ContentMediaService(
        currentUserId: () => uid,
        persistBytes: true,
        diskCache: disk,
        httpClient:
            MockClient((_) async => http.Response.bytes([1, 2, 3], 200)));
    final result = service.fetchBytes('asset');
    await disk.entered.future;
    uid = 'b';
    disk.release.complete();
    expect(await result, isNull);
  });
  test('one denied asset does not cancel another concurrent download',
      () async {
    final prefs = await SharedPreferences.getInstance();
    for (final id in ['denied', 'allowed']) {
      await prefs.setString(
          'content_media_url_v2__a|$id',
          jsonEncode({
            'signedUrl': 'https://example.com/$id',
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 10))
                .toIso8601String(),
          }));
    }
    final entered = Completer<void>();
    final allowed = Completer<http.Response>();
    final service = ContentMediaService(
        currentUserId: () => 'a',
        httpClient: MockClient((req) {
          if (req.url.path == '/denied')
            return Future.value(http.Response('', 403));
          entered.complete();
          return allowed.future;
        }));
    final success = service.fetchBytes('allowed');
    await entered.future;
    expect(await service.fetchBytes('denied'), isNull);
    allowed.complete(http.Response.bytes([7, 8], 200));
    expect(await success, [7, 8]);
  });
}
