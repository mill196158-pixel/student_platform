import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/pinned_media_switch.dart';

void main() {
  test('web and policy QA never enable the private runtime', () {
    expect(pinnedMediaRuntimeEnabled(web: true, platform: TargetPlatform.android, overrideValue: true, policyQa: false), isFalse);
    expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.android, overrideValue: true, policyQa: true), isFalse);
    expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.android, overrideValue: true, policyQa: false), isTrue);
    expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.android, overrideValue: false, policyQa: false), isFalse);
    expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.windows, overrideValue: false, policyQa: false), isFalse);
    expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.iOS, overrideValue: false, policyQa: false), isFalse);
    if (!const bool.fromEnvironment('PINNED_MEDIA_TEST_DESKTOP')) {
      expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.windows, overrideValue: true, policyQa: false), isFalse);
      expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.iOS, overrideValue: true, policyQa: false), isFalse);
    }
  });
}
