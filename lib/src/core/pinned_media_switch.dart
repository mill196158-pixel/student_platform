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

/// Shared source-document access fence; the pinned-media archive is separate.
bool sourceDocumentFenceEnabled({bool? web, TargetPlatform? platform, bool? overrideValue, bool? policyQa}) {
  if (web ?? kIsWeb) return false;
  if (policyQa ?? const bool.fromEnvironment('SQLITE_POLICY_QA')) return false;
  final target = platform ?? defaultTargetPlatform;
  if (target != TargetPlatform.android && target != TargetPlatform.iOS) return false;
  if (overrideValue != null) return overrideValue;
  if (const bool.hasEnvironment('SOURCE_DOCUMENT_FENCE_QA')) {
    return const bool.fromEnvironment('SOURCE_DOCUMENT_FENCE_QA');
  }
  return false;
}
