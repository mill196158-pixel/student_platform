import 'package:flutter/material.dart';

import 'admin_router.dart';
import 'admin_theme.dart';

class AdminApp extends StatelessWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Student Platform Admin',
      debugShowCheckedModeBanner: false,
      theme: AdminTheme.light,
      routerConfig: adminRouter,
    );
  }
}
