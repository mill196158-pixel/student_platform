import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app/admin_app.dart';
import 'core/auth/admin_session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Self-hosted assets pinned to pdfrx 2.4.5 under web/pdfium/.
  // No CDN dependency; see web/pdfium/SHA256SUMS.
  Pdfrx.pdfiumWasmModulesUrl = 'pdfium/';
  await pdfrxFlutterInitialize();

  // Auth client + onAuthStateChange must be ready before router/login UI.
  final session = AdminSessionController();
  await session.startAuthEarly();

  runApp(AdminApp(session: session));
}
