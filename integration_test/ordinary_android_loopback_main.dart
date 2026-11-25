// Exercise the ordinary application against a TLS backend on adb reverse.
// The private fixture directory supplies only the local public CA certificate.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:student_platform/main.dart' as app;
import 'package:student_platform/src/config/supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode ||
      !Platform.isAndroid ||
      SupabaseConfig.url != 'https://127.0.0.1:55443' ||
      (await PackageInfo.fromPlatform()).packageName !=
          'com.mill453020.studentplatform.offlinefixture') {
    throw StateError('An isolated loopback Android build is required.');
  }
  final files = await getApplicationSupportDirectory();
  final certificate =
      await File('${files.path}/ordinary_test_ca.pem').readAsBytes();
  SecurityContext.defaultContext.setTrustedCertificatesBytes(certificate);
  await app.main();
}
