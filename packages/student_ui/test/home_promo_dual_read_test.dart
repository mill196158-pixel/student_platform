import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

Map<String, dynamic> _row({
  required String id,
  required int schemaVersion,
  required String slot,
  required String variant,
}) {
  return {
    'id': id,
    'template_key': 'home_promo_v1',
    'schema_version': schemaVersion,
    'origin': 'admin',
    'placement': 'home_promo',
    'sort_order': 0,
    'priority': 0,
    'payload': {
      'title': '$variant@$slot',
      'subtitle': 'Subtitle',
      'icon_key': 'help',
      'cta_label': 'Open',
      'gradient_colors': ['#7367F0', '#B784F7'],
      'dismissible': true,
      'home_slot': slot,
      'card_variant': variant,
      'overlay_opacity': 0.35,
      'focal_x': 0.4,
      'focal_y': 0.6,
      'image_fit': 'cover',
      'action': {
        'kind': 'app_screen',
        'screen_key': 'diary',
      },
    },
  };
}

void main() {
  const slots = [
    'top',
    'after_news',
    'after_assignments',
    'after_deadlines',
    'bottom',
  ];
  const variants = [
    'image_full',
    'image_overlay',
    'image_top_text',
    'gradient_text',
    'compact_icon',
    'accent_info',
    'no_image',
  ];

  test('parses all 5 home slots × 7 variants for schema 1 and 2', () {
    for (final schema in [1, 2]) {
      for (final slot in slots) {
        for (final variant in variants) {
          final card = ManagedContentCard.tryParseHomePromo(
            _row(
              id: 'aaaaaaaa-bbbb-cccc-dddd-${schema.toString().padLeft(12, '0')}',
              schemaVersion: schema,
              slot: slot,
              variant: variant,
            ),
          );
          expect(card, isNotNull,
              reason: 'schema=$schema slot=$slot v=$variant');
          expect(card!.schemaVersion, schema);
          expect(card.homePromo.effectiveHomeSlot, slot);
          expect(card.homePromo.cardVariant, variant);
          expect(card.homePromo.overlayOpacity, 0.35);
          expect(card.homePromo.focalX, 0.4);
          expect(card.homePromo.focalY, 0.6);
          expect(card.homePromo.imageFit, 'cover');
          expect(
            ContentNavResolver.resolve(
              action: card.homePromo.action,
              ctaRoute: card.homePromo.ctaRoute,
              ctaUrl: card.homePromo.ctaUrl,
            ),
            isA<ContentNavDiary>(),
          );
        }
      }
    }
  });

  test('unknown variant/icon stay fail-safe without dropping card', () {
    final card = ManagedContentCard.tryParseHomePromo(
      _row(
        id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        schemaVersion: 2,
        slot: 'top',
        variant: 'not_a_real_variant',
      ),
    );
    expect(card, isNotNull);
    expect(card!.homePromo.cardVariant, 'not_a_real_variant');
    expect(card.homePromo.iconData, isNotNull);
  });
}
