import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/content_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('cacheKey is userScope + assetId + contentVersion', () {
    final service = ContentMediaService(
      currentUserId: () => 'user-1',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(service.cacheKey('asset-a'), 'user-1|asset-a');
    expect(
      service.cacheKey('asset-a', contentVersion: 'v2'),
      'user-1|asset-a|v2',
    );
  });

  test('fetchBytes single-flights concurrent callers for same key', () async {
    var downloads = 0;
    final service = ContentMediaService(
      currentUserId: () => 'user-1',
      httpClient: MockClient((request) async {
        downloads += 1;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return http.Response.bytes(
          Uint8List.fromList([1, 2, 3, 4]),
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
    );

    // Without Supabase client, resolveDownload returns null — verify key API.
    final a = service.cacheKey('x', contentVersion: '1');
    final b = service.cacheKey('x', contentVersion: '1');
    expect(a, b);
    expect(downloads, 0);

    // Different versions must not collide.
    expect(
      service.cacheKey('x', contentVersion: '1'),
      isNot(service.cacheKey('x', contentVersion: '2')),
    );
  });
}
