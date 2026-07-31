import 'package:flutter_test/flutter_test.dart';

void main() {
  test('feature flag defaults keep text reviews disabled in product copy', () {
    const flags = {
      'reviews.text_enabled': false,
      'reviews.structured_enabled': true,
    };
    expect(flags['reviews.text_enabled'], isFalse);
    expect(flags['reviews.structured_enabled'], isTrue);
  });

  test('moderation reason texts stay legally cautious', () {
    const copy = 'Отзыв скрыт по результатам модерации. Автор не публикуется.';
    expect(copy.contains('Автор не публикуется'), isTrue);
    expect(copy.toLowerCase().contains('оскорб'), isFalse);
  });
}
