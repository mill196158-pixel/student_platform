import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_platform/src/ui/chats/forward/forward_outbox_host.dart';

void main() {
  test('durable QA requires explicit opt-in on native Android', () {
    for (final platform in TargetPlatform.values) {
      for (final web in [false, true]) {
        expect(ForwardOutboxHost.androidQaModeFor(
          enabled: false, web: web, platform: platform), isFalse);
        expect(ForwardOutboxHost.androidQaModeFor(
          enabled: true, web: web, platform: platform),
          !web && platform == TargetPlatform.android);
      }
    }
  });
}
