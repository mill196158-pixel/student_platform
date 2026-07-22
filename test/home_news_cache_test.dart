import 'package:flutter/material.dart';
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

  test('published RPC row with image_path maps into HomeNewsItem', () {
    final item = mapPublishedNews({
      ...row(id: 'img-1', variant: 'imageOverlay', title: 'С фото'),
      'image_path':
          'news/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.png',
    });
    expect(item.imagePath, isNotNull);
    expect(item.variant, StudentHomeNewsVariant.imageOverlay);
    expect(item.icon, isNot(Icons.folder_copy_outlined));
  });

  test('cache-first then server refresh surfaces newly published news',
      () async {
    SharedPreferences.setMockInitialValues({});
    final cache = PublishedNewsCache();
    await cache.write([row(id: 'old')]);
    expect((await cache.read()).map((e) => e.id), ['old']);

    await cache.write([
      row(id: 'old'),
      row(id: 'new-pub', variant: 'imageWithText', title: 'Новая'),
    ]);
    final refreshed = await cache.read();
    expect(refreshed.map((e) => e.id), ['old', 'new-pub']);
    expect(refreshed.last.title, 'Новая');
  });
}
