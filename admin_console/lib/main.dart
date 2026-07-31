import 'package:flutter/widgets.dart';

import 'app/admin_app.dart';
import 'core/auth/admin_session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Auth client + onAuthStateChange must be ready before router/login UI.
  final session = AdminSessionController();
  await session.startAuthEarly();

  runApp(AdminApp(session: session));
}
