import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_ui/student_ui.dart';

void main() {
  for (final brightness in Brightness.values) {
    test('chat surfaces have readable foregrounds in $brightness', () {
      final colors = ProductTheme.build(brightness: brightness).colorScheme;
      for (final pair in [
        (colors.surface, colors.onSurface),
        (colors.primaryContainer, colors.onPrimaryContainer),
        (colors.secondaryContainer, colors.onSecondaryContainer),
      ]) {
        final a = pair.$1.computeLuminance();
        final b = pair.$2.computeLuminance();
        expect((math.max(a, b) + .05) / (math.min(a, b) + .05),
            greaterThanOrEqualTo(4.5));
      }
    });
  }
}
