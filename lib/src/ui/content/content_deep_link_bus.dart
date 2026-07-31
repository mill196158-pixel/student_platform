import 'package:flutter/foundation.dart';
import 'package:student_ui/student_ui.dart';

/// Cross-tab pending content deep links (Home/Profile → Info entities).
///
/// InfoScreen listens and consumes intents when the Info tab becomes active.
class ContentDeepLinkBus {
  ContentDeepLinkBus._();

  static final ContentDeepLinkBus instance = ContentDeepLinkBus._();

  final ValueNotifier<ContentNavIntent?> pending =
      ValueNotifier<ContentNavIntent?>(null);

  void publish(ContentNavIntent intent) {
    pending.value = intent;
  }

  ContentNavIntent? take() {
    final value = pending.value;
    pending.value = null;
    return value;
  }

  @visibleForTesting
  void debugClear() {
    pending.value = null;
  }
}
