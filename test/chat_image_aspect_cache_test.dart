import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/learning/widgets/chat_image_aspect_cache.dart';

void main() {
  test('remembers size only for the same user, session generation and URL', () {
    final cache = ChatImageAspectCache(maxEntries: 2);
    cache.remember(user: 'a', epoch: 1, url: 'image-a', ratio: 1.5);
    expect(cache.read(user: 'a', epoch: 1, url: 'image-a'), 1.5);
    expect(cache.read(user: 'b', epoch: 1, url: 'image-a'), isNull);
    expect(cache.read(user: 'a', epoch: 2, url: 'image-a'), isNull);
    expect(cache.read(user: 'a', epoch: 1, url: 'image-b'), isNull);
    cache.remember(user: null, epoch: 1, url: 'private', ratio: 1);
    expect(cache.read(user: null, epoch: 1, url: 'private'), isNull);
    cache.remember(user: 'a', epoch: 1, url: 'broken', ratio: double.nan);
    expect(cache.read(user: 'a', epoch: 1, url: 'broken'), isNull);
    cache.remember(user: 'a', epoch: 1, url: 'zero', ratio: 0);
    expect(cache.read(user: 'a', epoch: 1, url: 'zero'), isNull);
  });

  test('evicts least recently used sizes', () {
    final cache = ChatImageAspectCache(maxEntries: 2);
    void remember(String url) =>
        cache.remember(user: 'a', epoch: 1, url: url, ratio: 1);
    double? read(String url) => cache.read(user: 'a', epoch: 1, url: url);
    remember('first');
    remember('second');
    expect(read('first'), 1);
    remember('third');
    expect(read('second'), isNull);
    expect(read('first'), 1);
    expect(read('third'), 1);
  });
}
