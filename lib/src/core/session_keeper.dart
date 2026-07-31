import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session.dart';

/// Refreshes Supabase session while the app is open and when it returns
/// from background.
class SessionKeeper extends StatefulWidget {
  final Widget child;

  const SessionKeeper({super.key, required this.child});

  @override
  State<SessionKeeper> createState() => _SessionKeeperState();
}

class _SessionKeeperState extends State<SessionKeeper>
    with WidgetsBindingObserver {
  static const _refreshInterval = Duration(minutes: 25);

  Timer? _timer;
  final _client = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_refreshInterval, (_) => _refreshSilently());
    _refreshSilently();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshSilently();
    }
  }

  Future<void> _refreshSilently() async {
    try {
      await AuthSession.ensureFreshSession(_client);
    } catch (_) {
      // Ignore: individual screens retry on auth errors.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
