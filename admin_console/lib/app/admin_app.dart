import 'package:flutter/material.dart';

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
  late final router = createAdminRouter(_session);

  @override
  void initState() {
    super.initState();
    _session = widget.session ?? AdminSessionController();
    _session.bootstrap();
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
