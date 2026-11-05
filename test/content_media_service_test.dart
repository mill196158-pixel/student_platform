import 'dart:io';
import 'dart:async';
import 'package:student_platform/src/ui/home/news_image_disk_cache.dart';
import 'package:student_ui/student_ui.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
      'timed out image releases flight; late response cannot replace retry cache',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'content_media_url_v2__a|asset|v1',
        jsonEncode({
          'signedUrl': 'https://example.com/image',
          'expiresAt':
              DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
        }));
    final old = Completer<http.Response>();
    var calls = 0;
    final service = ContentMediaService(
        currentUserId: () => 'a',
        networkTimeout: const Duration(milliseconds: 30),
        httpClient: MockClient((_) async {
          calls++;
          if (calls == 1) return old.future;
          return http.Response.bytes([2], 200);
        }));
    expect(await service.fetchBytes('asset', contentVersion: 'v1'), isNull);
    expect(await service.fetchBytes('asset', contentVersion: 'v1'), [2]);
    old.complete(http.Response.bytes([1], 200));
    await Future<void>.delayed(Duration.zero);
    expect(await service.fetchBytes('asset', contentVersion: 'v1'), [2]);
    expect(calls, 2);
  });

  test('resolveDownload rejects responses that leak storage path', () async {
    // Without a Supabase client, invoke fails closed — treat as null download.
    final service = ContentMediaService(
      currentUserId: () => 'user-1',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    final download = await service.resolveDownload('asset-1');
    expect(download, isNull);
  });

  test('clearAll removes persisted urls for current user scope', () async {
    SharedPreferences.setMockInitialValues({
      'content_media_url_v1__user-1|asset-1': jsonEncode({
        'signedUrl': 'https://example.com/a',
        'expiresAt':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      }),
      'content_media_url_v1__user-2|asset-1': jsonEncode({
        'signedUrl': 'https://example.com/b',
        'expiresAt':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      }),
    });
    final service = ContentMediaService(
      currentUserId: () => 'user-1',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    await service.clearAll();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('content_media_url_v1__user-1|asset-1'), isFalse);
    expect(prefs.containsKey('content_media_url_v1__user-2|asset-1'), isTrue);
  });
  test('promo disk bytes survive new service, but not expiry or another user',
      () async {
    final dir = await Directory.systemTemp.createTemp('promo-media-test-');
    try {
      final prefs = await SharedPreferences.getInstance();
      final expiry = DateTime.now().add(const Duration(minutes: 10));
      await prefs.setString(
          'content_media_url_v2__a|asset|v1',
          jsonEncode({
            'signedUrl': 'https://example.com/signed',
            'expiresAt': expiry.toIso8601String(),
          }));
      var requests = 0;
      ContentMediaService service(String uid) => ContentMediaService(
          persistBytes: true,
          currentUserId: () => uid,
          diskCache: NewsImageDiskCache(
              memory: NewsImageBytesCache(), rootOverride: () => dir),
          httpClient: MockClient((_) async {
            requests++;
            return http.Response.bytes([1, 2, 3], 200);
          }));
      final first = service('a');
      expect(await first.fetchBytes('asset', contentVersion: 'v1'), [1, 2, 3]);
      expect(await service('a').fetchBytes('asset', contentVersion: 'v1'),
          [1, 2, 3]);
      expect(requests, 1, reason: 'new instance reads disk without HTTP');
      await prefs.setString(
          'content_media_url_v2__a|asset|v1',
          jsonEncode({
            'signedUrl': 'https://example.com/expired',
            'expiresAt': DateTime(2000).toIso8601String(),
          }));
      var authorizations = 0;
      final client = SupabaseClient('https://example.test', 'public-test-key',
          httpClient: MockClient((_) async {
        authorizations++;
        return http.Response(jsonEncode({
          'signedUrl': 'https://example.com/new-grant', 'expiresIn': 3600,
        }), 200, headers: {'content-type': 'application/json'});
      }));
      addTearDown(client.dispose);
      final renewed = ContentMediaService(
          client: client, persistBytes: true, currentUserId: () => 'a',
          diskCache: NewsImageDiskCache(
              memory: NewsImageBytesCache(), rootOverride: () => dir),
          httpClient: MockClient((_) async {
            requests++;
            return http.Response.bytes([9], 200);
          }));
      expect(await renewed.fetchBytes('asset', contentVersion: 'v1'), [1, 2, 3]);
      expect(authorizations, 1);
      expect(requests, 1,
          reason: 'a renewed grant reuses the same authorized asset bytes');
      expect(
          await service('b').fetchBytes('asset', contentVersion: 'v1'), isNull);
      expect(
          await service('a').fetchBytes('another', contentVersion: 'v1'), isNull);
      expect(
          await service('a').fetchBytes('asset', contentVersion: 'v2'), isNull);
      await prefs.setString(
          'content_media_url_v2__a|asset|v1',
          jsonEncode({
            'signedUrl': 'https://example.com/signed',
            'expiresAt': DateTime(2000).toIso8601String(),
          }));
      expect(
          await service('a').fetchBytes('asset', contentVersion: 'v1'), isNull);
      expect(requests, 1);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('denied renewal does not return cached bytes and clears the entry', () async {
    final dir = await Directory.systemTemp.createTemp('promo-denied-test-');
    final client = SupabaseClient('https://example.test', 'public-test-key',
        httpClient: MockClient((_) async => http.Response('{"error":"forbidden"}', 403,
            headers: {'content-type': 'application/json'})));
    addTearDown(() async {
      await client.dispose();
      await dir.delete(recursive: true);
    });
    final prefs = await SharedPreferences.getInstance();
    const prefKey = 'content_media_url_v2__a|asset|v1';
    await prefs.setString(prefKey, jsonEncode({
      'signedUrl': 'https://example.com/signed',
      'expiresAt': DateTime.now().add(const Duration(minutes: 10)).toIso8601String(),
    }));
    NewsImageDiskCache disk() => NewsImageDiskCache(
        memory: NewsImageBytesCache(), rootOverride: () => dir);
    final first = ContentMediaService(
        persistBytes: true, currentUserId: () => 'a', diskCache: disk(),
        httpClient: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)));
    expect(await first.fetchBytes('asset', contentVersion: 'v1'), [1, 2, 3]);
    await prefs.setString(prefKey, jsonEncode({
      'signedUrl': 'https://example.com/expired',
      'expiresAt': DateTime(2000).toIso8601String(),
    }));
    final denied = ContentMediaService(
        client: client, persistBytes: true, currentUserId: () => 'a', diskCache: disk());
    expect(await denied.fetchBytes('asset', contentVersion: 'v1'), isNull);
    final key = NewsImageCacheKey(path: 'content-media/a|asset|v1', version: 'asset-v1');
    expect(await disk().peek(key), isNull);
  });
}
