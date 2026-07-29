import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/info/vacancy_media_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('clearAll removes persisted urls for current user scope', () async {
    SharedPreferences.setMockInitialValues({
      'vacancy_media_url_v1|user-1|asset-1': jsonEncode({
        'signedUrl': 'https://example.com/a',
        'expiresAt':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      }),
      'vacancy_media_url_v1|user-2|asset-1': jsonEncode({
        'signedUrl': 'https://example.com/b',
        'expiresAt':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      }),
    });
    final service = VacancyMediaService(
      currentUserId: () => 'user-1',
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    await service.clearAll();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('vacancy_media_url_v1|user-1|asset-1'), isFalse);
    expect(prefs.containsKey('vacancy_media_url_v1|user-2|asset-1'), isTrue);
  });
}
