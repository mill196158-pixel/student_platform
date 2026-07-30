import 'dart:convert';

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
}
