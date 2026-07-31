import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'package:student_platform/firebase_options.dart';

/// Top-level background isolate handler. No navigation / BuildContext.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[Push] background Firebase init skipped: $e');
    }
  }

  if (kDebugMode) {
    final type = message.data['type'];
    debugPrint('[Push] background message type=$type');
  }
}
