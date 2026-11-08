import 'dart:async';
import 'package:flutter/widgets.dart';
import '../ui/chats/core/project_chat_server_cache.dart';
import 'optional_image_cache_budget.dart';
import 'ordinary_history_maintenance.dart';
import 'session_capabilities.dart';

/// Runs one background pass after the online shell is visible.
class OrdinaryHistoryMaintenanceHost extends StatefulWidget {
  const OrdinaryHistoryMaintenanceHost({super.key, required this.cache,
    required this.capabilities, required this.budget, required this.probeOnline,
    required this.isCurrent, required this.child, this.debugOnStart});
  final ProjectChatServerCache cache;
  final SessionCapabilities capabilities;
  final OptionalImageCacheBudget budget;
  final Future<bool> Function() probeOnline;
  final bool Function() isCurrent;
  final Widget child;
  @visibleForTesting
  final void Function()? debugOnStart;
  @override
  State<OrdinaryHistoryMaintenanceHost> createState() => _OrdinaryHistoryMaintenanceHostState();
}

class _OrdinaryHistoryMaintenanceHostState extends State<OrdinaryHistoryMaintenanceHost> {
  Timer? _timer;
  int _epoch = 0;
  @override
  void initState() { super.initState(); _schedule(); }

  void _schedule() {
    final epoch = ++_epoch;
    final cache = widget.cache, caps = widget.capabilities, budget = widget.budget;
    _timer = Timer(const Duration(seconds: 5), () {
      bool valid() {
        try { return mounted && epoch == _epoch && widget.isCurrent(); } catch (_) { return false; }
      }
      if (!valid()) return;
      widget.debugOnStart?.call();
      final pass = OrdinaryHistoryMaintenance(cache: cache, capabilities: caps,
        budget: budget, probeOnline: () => widget.probeOnline(), isCurrent: valid);
      unawaited(pass.run());
    });
  }

  @override
  void didUpdateWidget(covariant OrdinaryHistoryMaintenanceHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cache, widget.cache) ||
        !identical(oldWidget.capabilities, widget.capabilities) ||
        !identical(oldWidget.budget, widget.budget)) {
      _timer?.cancel();
      _schedule();
    }
  }

  @override
  void dispose() { _epoch++; _timer?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => widget.child;
}
