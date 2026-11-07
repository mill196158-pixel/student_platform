import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/core/pinned_media_availability.dart';
import 'package:student_platform/src/core/pinned_media_switch.dart';
import 'package:student_platform/src/services/chat_file_access.dart';

void main() {
  test('document barrier is isolated from the pinned archive and only on mobile', () async {
    expect(pinnedMediaRuntimeEnabled(web: false, platform: TargetPlatform.android,
        overrideValue: false, policyQa: false), isFalse);
    expect(sourceDocumentFenceEnabled(web: false, platform: TargetPlatform.android,
        overrideValue: true, policyQa: false), isTrue);
    expect(sourceDocumentFenceEnabled(web: false, platform: TargetPlatform.iOS,
        overrideValue: true, policyQa: false), isTrue);
    expect(sourceDocumentFenceEnabled(web: false, platform: TargetPlatform.windows,
        overrideValue: true, policyQa: false), isFalse);
    expect(sourceDocumentFenceEnabled(web: true, platform: TargetPlatform.android,
        overrideValue: true, policyQa: false), isFalse);
    expect(sourceDocumentFenceEnabled(web: false, platform: TargetPlatform.android,
        overrideValue: true, policyQa: true), isFalse);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    if (const bool.fromEnvironment('SOURCE_DOCUMENT_FENCE_QA')) {
      expect(ChatFileAccess.mediaProtection, isNull);
      await expectLater(ChatFileAccess.resolve('https://studentsplatform.storage.yandexcloud.net/chats/a/file'),
          throwsA(isA<MediaProtectionUnavailable>()));
      expect(await ChatFileAccess.resolve('https://example.test/public'), 'https://example.test/public');
    } else {
      expect(sourceDocumentFenceEnabled(web: false, platform: TargetPlatform.android, policyQa: false), isFalse);
    }
  });
}
