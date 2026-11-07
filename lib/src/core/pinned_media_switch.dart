import 'package:flutter/foundation.dart';

/// Central predicate for both bootstrap and all private-file gates.
/// The production default remains off until reviewed and device-verified.
bool pinnedMediaRuntimeEnabled({bool? web, TargetPlatform? platform, bool? overrideValue, bool? policyQa}) {
  final isWeb = web ?? kIsWeb;
  final target = platform ?? defaultTargetPlatform;
  final qa = policyQa ?? const bool.fromEnvironment('SQLITE_POLICY_QA');
  if (isWeb || qa) return false;
  if (target != TargetPlatform.android &&
      !const bool.fromEnvironment('PINNED_MEDIA_TEST_DESKTOP')) return false;
  if (overrideValue != null) return overrideValue;
  if (const bool.hasEnvironment('PINNED_MEDIA_RUNTIME')) {
    return const bool.fromEnvironment('PINNED_MEDIA_RUNTIME');
  }
  // Kept explicit so Android can be enabled independently after approval.
  return target == TargetPlatform.android && false;
}

/// Quarantined until independent review and Android multi-engine verification.
/// It enables the shared access fence, not the pinned-media archive.
bool sourceDocumentFenceEnabled({bool? web, TargetPlatform? platform, bool? overrideValue, bool? policyQa}) {
  if (web ?? kIsWeb) return false;
  if (policyQa ?? const bool.fromEnvironment('SQLITE_POLICY_QA')) return false;
  final target = platform ?? defaultTargetPlatform;
  if (target != TargetPlatform.android && target != TargetPlatform.iOS) return false;
  return overrideValue ?? const bool.fromEnvironment('SOURCE_DOCUMENT_FENCE_QA');
}
