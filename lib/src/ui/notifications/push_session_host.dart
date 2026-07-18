import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:student_platform/src/services/push/push_navigation.dart';
import 'package:student_platform/src/services/push/push_notification_service.dart';

/// Starts push after auth and flushes pending deep links once the shell is ready.
class PushSessionHost extends StatefulWidget {
  const PushSessionHost({super.key, required this.child});

  final Widget child;

  @override
  State<PushSessionHost> createState() => _PushSessionHostState();
}

class _PushSessionHostState extends State<PushSessionHost> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_started) return;
    if (Supabase.instance.client.auth.currentUser == null) return;
    _started = true;

    await PushNotificationService.instance.onAuthenticated(context);
    if (!mounted) return;
    await PushNavigation.flushPending(context);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
