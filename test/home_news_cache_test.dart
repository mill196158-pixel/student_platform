import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:student_ui/student_ui.dart';

import 'package:student_platform/src/ui/home/home_dashboard_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> row({
    required String id,
    String variant = 'gradientText',
    String title = 'Заголовок',
  }) {
    return {
      'id': id,
      'status': 'published',
      'variant': variant,
      'title': title,
      'subtitle': 'Подзаголовок',
      'body': 'Текст',
      'gradient_colors': ['#7367F0', '#B784F7'],
      'image_path': null,
      'image_focus_x': 0.0,
      'image_focus_y': 0.0,
      'overlay_opacity': 0.42,
      'priority': 0,
      'published_at': '2026-07-22T08:00:00Z',
      'created_at': '2026-07-22T07:00:00Z',
    };
  }

  test('mapPublishedNews maps variant, colors and dates', () {
    final item = mapPublishedNews(row(
      id: 'a',
      variant: 'imageOverlay',
      title: 'Событие',
    ));

    expect(item.id, 'a');
    expect(item.title, 'Событие');
    expect(item.variant, StudentHomeNewsVariant.imageOverlay);
    expect(item.gradientColors, hasLength(2));
    expect(item.publishedAt, isNotNull);
  });

  test('cache write then read round-trips items', () async {
    SharedPreferences.setMockInitialValues({});
    final cache = PublishedNewsCache();

    expect(await cache.read(), isEmpty);

    await cache.write([row(id: 'a'), row(id: 'b', variant: 'imageOnly')]);

    final items = await cache.read();
    expect(items, hasLength(2));
    expect(items.first.id, 'a');
    expect(items[1].variant, StudentHomeNewsVariant.imageOnly);
  });

  test('empty stored value yields an empty list', () async {
    SharedPreferences.setMockInitialValues({
      PublishedNewsCache.key: '',
    });
    final cache = PublishedNewsCache();
    expect(await cache.read(), isEmpty);
  });
}
