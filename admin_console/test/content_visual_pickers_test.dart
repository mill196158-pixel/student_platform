import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform_admin/features/content/shared/content_action_model.dart';
import 'package:student_platform_admin/features/content/shared/content_action_picker.dart';
import 'package:student_platform_admin/features/content/shared/content_color_utils.dart';
import 'package:student_platform_admin/features/content/shared/content_icon_catalog.dart';
import 'package:student_platform_admin/features/content/shared/content_card_variant_picker.dart';
import 'package:student_platform_admin/features/content/shared/content_preview_binder.dart';
import 'package:student_platform_admin/features/content/shared/content_preview_mode.dart';
import 'package:student_platform_admin/features/content/shared/content_placement_slot_picker.dart';

void main() {
  group('content icon catalog', () {
    test('search finds Russian label', () {
      final results = searchContentIconsByRuName('психолог');
      expect(results, isNotEmpty);
      expect(
        results.any(
          (e) => e.key == 'psychology' || e.key == 'psychology_alt_outlined',
        ),
        isTrue,
      );
    });

    test('list by category returns study icons', () {
      final study = listContentIconsByCategory(ContentIconCategory.study);
      expect(study.any((e) => e.key == 'school'), isTrue);
    });
  });

  group('content action picker https validation', () {
    test('validateContentExternalUrl rejects http', () {
      expect(
        validateContentExternalUrl('http://example.com'),
        contains('HTTPS'),
      );
    });

    test('validateContentExternalUrl accepts https', () {
      expect(validateContentExternalUrl('https://example.com'), isNull);
    });

    testWidgets('shows error for non-https URL in picker', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentActionPicker(
              selection: const ContentActionSelection(
                kind: ContentActionKind.externalUrl,
                url: 'http://bad.example',
              ),
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('HTTPS'), findsOneWidget);
    });
  });

  group('placement labels', () {
    test('maps after_news to Russian label', () {
      expect(contentHomeSlotLabelRu('after_news'), 'После новостей');
    });

    test('maps after_assignments to Russian label', () {
      expect(
        contentHomeSlotLabelRu('after_assignments'),
        'После ближайших дел',
      );
    });

    test('defaults unknown slot to after_assignments label', () {
      expect(contentHomeSlotLabelRu('unknown_slot'), 'После ближайших дел');
    });
  });

  group('gradient contrast helper', () {
    test('warns on low contrast pale-on-white', () {
      const pale = Color(0xFFF3EEF9);
      const white = Color(0xFFFFFFFF);
      final warning = contentContrastWarning(
        foreground: white,
        background: pale,
      );
      expect(warning, isNotNull);
      expect(warning!, contains('контраст'));
    });

    test('passes for dark text on cream background', () {
      const cream = Color(0xFFFFFBFF);
      const dark = Color(0xFF121212);
      final warning = contentContrastWarning(
        foreground: dark,
        background: cream,
      );
      expect(warning, isNull);
    });

    test('contentRelativeLuminance is ordered for black vs white', () {
      expect(
        contentRelativeLuminance(Colors.black),
        lessThan(contentRelativeLuminance(Colors.white)),
      );
    });
  });

  group('legacy action projection', () {
    test('legacyCtaRouteForAction maps screens to Mobile/SQL routes', () {
      expect(
        legacyCtaRouteForAction(
          const ContentActionSelection(
            kind: ContentActionKind.appScreen,
            screenKey: 'home',
          ),
        ),
        '/home',
      );
      expect(
        legacyCtaRouteForAction(
          const ContentActionSelection(
            kind: ContentActionKind.appScreen,
            screenKey: 'diary',
          ),
        ),
        '/my-diary',
      );
      expect(
        legacyCtaRouteForAction(
          const ContentActionSelection(
            kind: ContentActionKind.appScreen,
            screenKey: 'info',
          ),
        ),
        '/help',
      );
    });

    test('contentActionFromLegacy maps /help to info screen key', () {
      final action = contentActionFromLegacy(
        ctaAction: 'route',
        ctaRoute: '/help',
        ctaUrl: '',
      );
      expect(action.kind, ContentActionKind.appScreen);
      expect(action.screenKey, 'info');
    });

    test('contentWireUsesV2PublishFeatures detects non-default slot', () {
      expect(
        contentWireUsesV2PublishFeatures({'home_slot': 'after_news'}),
        isTrue,
      );
      expect(
        contentWireUsesV2PublishFeatures({'home_slot': 'after_assignments'}),
        isFalse,
      );
    });

    test('contentActionToWire round-trips app screen', () {
      const selection = ContentActionSelection(
        kind: ContentActionKind.appScreen,
        screenKey: 'info',
      );
      final wire = contentActionToWire(selection);
      expect(wire['kind'], 'app_screen');
      expect(wire['screen_key'], 'info');
      final parsed = contentActionFromWire(wire);
      expect(parsed.kind, ContentActionKind.appScreen);
      expect(parsed.screenKey, 'info');
    });
  });

  group('home promo v2 draft pickers', () {
    testWidgets('ContentPlacementSlotPicker renders slot labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentPlacementSlotPicker(
              selected: ContentHomeSlot.afterAssignments,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Место на главной'), findsOneWidget);
    });

    testWidgets('ContentCardVariantPicker renders variant labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentCardVariantPicker(
              selected: ContentCardVariant.gradientText,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Вариант карточки'), findsOneWidget);
    });
  });

  group('preview binder', () {
    test('shouldOverlayLiveDraft when effectiveDraft and dirty', () {
      expect(
        shouldOverlayLiveDraft(
          isDraft: false,
          editingWorkingDraft: false,
          dirty: true,
          mode: ContentPreviewMode.effectiveDraft,
        ),
        isTrue,
      );
    });

    test('publishedCanonical never overlays', () {
      expect(
        shouldOverlayLiveDraft(
          isDraft: true,
          editingWorkingDraft: true,
          dirty: true,
          mode: ContentPreviewMode.publishedCanonical,
        ),
        isFalse,
      );
    });
  });
}
