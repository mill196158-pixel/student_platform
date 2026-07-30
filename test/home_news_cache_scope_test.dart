import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_platform/src/ui/home/home_dashboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PublishedNewsCache isolates users A and B', () async {
    SharedPreferences.setMockInitialValues({});
    String? user = 'user-a';
    final cache = PublishedNewsCache(currentUserId: () => user);

    await cache.write([
      {
        'id': 'n1',
        'title': 'A only',
        'subtitle': '',
        'body': '',
        'variant': 'gradientText',
        'gradient_colors': ['#111111', '#222222'],
        'priority': 0,
        'created_at': DateTime.now().toIso8601String(),
      },
    ]);

    user = 'user-b';
    expect(await cache.read(), isEmpty);

    user = 'user-a';
    final aRows = await cache.read();
    expect(aRows, hasLength(1));
    expect(aRows.first.title, 'A only');

    await cache.clearAll();
    expect(await cache.read(), isEmpty);
  });
}
