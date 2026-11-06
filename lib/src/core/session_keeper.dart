import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session.dart';
import 'online_side_effect_barrier.dart';

/// Refreshes Supabase session while the app is open and when it returns
/// from background.
class SessionKeeper extends StatefulWidget {
  final Widget child;
  final OnlineSideEffectBarrier? barrier;
  @visibleForTesting
  final Future<void> Function()? refreshOverride;

  const SessionKeeper({super.key, required this.child, this.barrier, this.refreshOverride});

  @override
  State<SessionKeeper> createState() => _SessionKeeperState();
}

class _SessionKeeperState extends State<SessionKeeper>
    with WidgetsBindingObserver {
  static const _refreshInterval = Duration(minutes: 25);

  Timer? _timer;
  late final _client = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(_refreshInterval, (_) => _refreshSilently());
    _refreshSilently();
  }

  @override
  void dispose() {
    widget.barrier?.close();
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SessionKeeper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.barrier, widget.barrier)) {
      oldWidget.barrier?.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshSilently();
    }
  }

  Future<void> _refreshSilently() async {
    try {
      Future<void> refresh() => widget.refreshOverride?.call() ??
          AuthSession.ensureFreshSession(_client);
      final barrier = widget.barrier;
      if (barrier == null) {
        await refresh();
      } else {
        await barrier.run(refresh);
      }
    } catch (_) {
      // Ignore: individual screens retry on auth errors.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
