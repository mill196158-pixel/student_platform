import 'package:flutter/foundation.dart';

Stopwatch? _qaClock;
int _qaSequence = 0;
int? qaReentryNext() => kDebugMode && const bool.fromEnvironment('QA_REENTRY_TIMING')
    ? ++_qaSequence : null;
void qaReentryTiming(String stage, [int? sequence]) {
  if (kDebugMode && const bool.fromEnvironment('QA_REENTRY_TIMING')) {
    final clock = _qaClock ??= Stopwatch()..start();
    debugPrint('QA_REENTRY_TIMING ${clock.elapsedMilliseconds} $stage ${sequence ?? 0}');
  }
}
