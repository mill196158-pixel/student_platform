import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/admin_session_controller.dart';
import 'admin_router.dart';
import 'admin_theme.dart';

class AdminApp extends StatefulWidget {
  const AdminApp({super.key, this.session});

  final AdminSessionController? session;

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  late final AdminSessionController _session;
  late final GoRouter router;

  @override
  void initState() {
    super.initState();
    _session = widget.session ?? AdminSessionController();
    router = createAdminRouter(_session);

    if (widget.session != null) {
      // main() already ran startAuthEarly(); finish capability/session path.
      _session.completeBootstrap();
    } else {
      // Tests / fallback without early auth.
      _session.bootstrap();
    }
  }

  @override
  void dispose() {
    if (widget.session == null) {
      _session.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Student Platform Admin',
      debugShowCheckedModeBanner: false,
      theme: AdminTheme.light,
      routerConfig: router,
    );
  }
}
